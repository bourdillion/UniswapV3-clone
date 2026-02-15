//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IUniswapV3PoolDeployer} from "./interface/IUniswapV3PoolDeployer.sol";
import {IUniswapV3Factory} from "./interface/IUniswapV3Factory.sol";
import {safeCast} from "./libraries/safeCast.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {Position} from "./libraries/Position.sol";
import {Oracle} from "./libraries/Oracle.sol";
import {Tick} from "./libraries/Tick.sol";
import {TickBitMap} from "./libraries/TickBitMap.sol";
import {IUniswapV3MintCallback} from "./interface/IUniswapV3MintCallback.sol";
import {IERC20Minimal} from "./interface/IERC20Minimal.sol";
import {SqrtPriceMath} from "./libraries/SqrtPriceMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {LowGasSafeMath} from "./libraries/LowGasSafeMath.sol";
import {TransferHelper} from "./libraries/TransferHelper.sol";
import {NoDelegateCall} from "./NoDelegateCall.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {FixedPoint96} from "./libraries/FixedPoint96.sol";
import {FixedPoint128} from "./libraries/FixedPoint128.sol";
import {IUniswapV3SwapCallback} from "./interface/IUniswapV3SwapCallback.sol";
import {IUniswapV3FlashCallback} from "./interface/IUniswapV3FlashCallBack.sol";

contract UniswapV3Pool is NoDelegateCall {
    ///////////////////////////
    //Library Initialization///
    //////////////////////////

    using safeCast for uint256;
    using safeCast for int256;
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Oracle for Oracle.Observation[65535];
    using Tick for mapping(int24 => Tick.Info);
    using TickBitMap for mapping(int16 => uint256);
    using LowGasSafeMath for uint256;
    using LowGasSafeMath for int256;

    ///////////
    //error///
    /////////
    error PoolLocked();
    error Unauthorized();
    error ZeroValue();
    error InvalidInput();
    error InsufficientLiquidity();

    //////////
    //events//
    //////////
    event ObservationcardinalityIncreased(uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew);
    event Mint(
        address sender,
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Burn(address owner, int24 tickLower, int24 tickUpper, uint128 amount, uint128 amount0, uint128 amount1);
    event Collect(address owner, address recipient, int24 tickLower, int24 tickUpper, uint128 amount0, uint128 amount1);
    event SetFeeProtocol(uint8 feeProtocolOld0, uint8 feeProtocolOld1, uint8 feeProtocol0, uint8 feeProtocol1);
    event Flash(address sender, address recipient, uint256 amount0, uint256 amount1, uint256 paid0, uint256 paid1);

    /////////////
    //variables//
    ////////////

    //Immutable variables
    address public immutable factory;
    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public liquidity;
    uint128 public immutable maxLiquidityPerTick;

    //Mappings
    mapping(int24 => Tick.Info) public ticks;
    //This tracks each position
    mapping(bytes32 => Position.Info) public positions;
    mapping(int16 => uint256) public tickBitmap;

    //Public Variables
    //this tracks the growth rate of fees gotten in token0 based on the total liquidity
    /**
     *                           Total fee collected in token0
     * feeGrowthGlobal0x128 =   ------------------------------- x 2^128
     *                           Total liquidity in this token0
     *
     * it is stored as a fixed point number to account for the decimals.
     */
    uint256 public feeGrowthGlobal0X128;
    //this tracks the growth rate of fees gotten in token1 based on the total liquidity
    /**
     *                            Total fee collected in token1
     * feeGrowthGlobal1x128 =   ------------------------------- x 2^128
     *                           Total liquidity in this token1
     *
     * it is stored as a fixed point number to account for the decimals.
     */
    uint256 public feeGrowthGlobal1X128;
    Oracle.Observation[65535] public observations;
    ProtocolFees public protocolFees;

    //Struct

    struct ProtocolFees {
        uint128 token0;
        uint128 token1;
    }

    struct ModifyPositionParams {
        // the address that owns the position
        address owner;
        // the lower and upper tick of the position
        int24 tickLower;
        int24 tickUpper;
        // any change in liquidity
        int128 liquidityDelta;
    }

    struct Slot0 {
        //To save gas and space, Uniswap grouped all low level integer into one slot space of uint256

        //This is the square root of the price stored in a fixed point Q64.96, that is the value is multiplied by 2^96 or number << 96

        /**
         * This is given by
         * sqrtPriceX96 = 2^96 x sqrt(1.0001)^t
         * where t is tick
         */
        uint160 sqrtPriceX96;
        //sectional number use to represent price, tick is gotten by
        /**
         *
         *
         * t(tick) = 2ln(sqrtPriceX96/2^96)
         *           ----------------------
         *               ln(1.0001)
         *
         */
        int24 tick;
        uint16 observationIndex;
        uint16 observationCardinality;
        uint16 observationCardinalityNext;
        //the percentage of fee charged by the protocol
        uint8 feeProtocol;
        bool unlocked;
    }

    //Initialize the struct
    Slot0 public slot0;

    ////////////////
    //Constructors//
    ///////////////

    constructor() {
        (factory, token0, token1, fee, tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();

        maxLiquidityPerTick = maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(tickSpacing);
    }

    /////////////
    //Modifiers//
    ////////////

    modifier lock() {
        if (!slot0.unlocked) {
            revert PoolLocked();
        }
        slot0.unlocked = true;
        _;
        slot0.unlocked = false;
    }

    modifier onlyFactoryOwner() {
        if (msg.sender != IUniswapV3Factory(factory).owner()) {
            revert Unauthorized();
        }
        _;
    }

    ///////////////////////////
    //View and pure Functions//
    //////////////////////////

    //force the block.timestamp to a unit32 porcche
    function _blockTimestamp() internal view virtual returns (uint32) {
        return uint32(block.timestamp);
    }

    function balance0() private view returns (uint256) {
        (bool success, bytes memory data) =
            token0.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function balance1() private view returns (uint256) {
        (bool success, bytes memory data) =
            token1.staticcall(abi.encodeWithSelector(IERC20Minimal.balanceOf.selector, address(this)));
        require(success && data.length >= 32);
        return abi.decode(data, (uint256));
    }

    function checkTicks(int24 tickLower, int24 tickUpper) private pure {
        if (tickLower > tickUpper) {
            revert InvalidInput();
        }
        if (tickLower < TickMath.MIN_TICK || tickUpper > TickMath.MAX_TICK) {
            revert InvalidInput();
        }
    }

    function snapshotCumulativesInside(int24 tickLower, int24 tickUpper)
        external
        view
        noDelegateCall
        returns (int56 tickCumulativeInside, uint160 secondsPerLiquidityInsideX128, uint32 secondsInside)
    {
        checkTicks(tickLower, tickUpper);

        int56 tickCumulativeLower;
        int56 tickCumulativeUpper;
        uint160 secondsPerLiquidityOutsideLowerX128;
        uint160 secondsPerLiquidityOutsideUpperX128;
        uint32 secondsOutsideLower;
        uint32 secondsOutsideUpper;

        {
            Tick.Info storage lower = ticks[tickLower];
            Tick.Info storage upper = ticks[tickUpper];
            bool initializedLower;
            (tickCumulativeLower, secondsPerLiquidityOutsideLowerX128, secondsOutsideLower, initializedLower) = (
                lower.tickCumulativeOutside,
                lower.secondsPerLiquidityOutsideX128,
                lower.secondsOutside,
                lower.initialized
            );
            require(initializedLower);

            bool initializedUpper;
            (tickCumulativeUpper, secondsPerLiquidityOutsideUpperX128, secondsOutsideUpper, initializedUpper) = (
                upper.tickCumulativeOutside,
                upper.secondsPerLiquidityOutsideX128,
                upper.secondsOutside,
                upper.initialized
            );
            require(initializedUpper);
        }

        Slot0 memory _slot0 = slot0;

        if (_slot0.tick < tickLower) {
            return (
                tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityOutsideLowerX128 - secondsPerLiquidityOutsideUpperX128,
                secondsOutsideLower - secondsOutsideUpper
            );
        } else if (_slot0.tick < tickUpper) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time, 0, _slot0.tick, _slot0.observationIndex, liquidity, _slot0.observationCardinality
            );
            return (
                tickCumulative - tickCumulativeLower - tickCumulativeUpper,
                secondsPerLiquidityCumulativeX128 - secondsPerLiquidityOutsideLowerX128
                    - secondsPerLiquidityOutsideUpperX128,
                time - secondsOutsideLower - secondsOutsideUpper
            );
        } else {
            return (
                tickCumulativeUpper - tickCumulativeLower,
                secondsPerLiquidityOutsideUpperX128 - secondsPerLiquidityOutsideLowerX128,
                secondsOutsideUpper - secondsOutsideLower
            );
        }
    }

    function observe(uint32[] calldata secondsAgos)
        external
        view
        noDelegateCall
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s)
    {
        return observations.observe(
            _blockTimestamp(), secondsAgos, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
        );
    }

    /////////////////////////////////
    //Public and External Functions//
    ////////////////////////////////

    function mint(address recipient, int24 lowerTick, int24 upperTick, uint256 amount, bytes calldata data)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        //check that amount and recipient is not zero
        if (recipient == address(0)) {
            revert ZeroValue();
        }
        if (amount <= 0) {
            revert ZeroValue();
        }

        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: recipient,
                tickLower: lowerTick,
                tickUpper: upperTick,
                liquidityDelta: int256(amount).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount > 0) balance0Before = balance0();
        if (amount > 0) balance1Before = balance1();

        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        if (amount0 > 0) {
            if (balance0Before.addInt(amount0Int) > balance0()) {
                revert InsufficientLiquidity();
            }
        }

        if (amount1 > 0) {
            if (balance1Before.addInt(amount1Int) > balance1()) {
                revert InsufficientLiquidity();
            }
        }

        emit Mint(msg.sender, recipient, lowerTick, upperTick, amount, amount0, amount1);
    }

    function burn(int24 tickLower, int24 tickUpper, uint128 amount)
        external
        lock
        returns (uint256 amount0, uint256 amount1)
    {
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(amount).toInt128()
            })
        );

        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            (position.tokensOwed0, position.tokensOwed1) =
                (position.tokenOwned0 + uint128(amount0), position.tokenOwned1 + uint128(amount1));
        }

        emit Burn(msg.sender, tickLower, tickUpper, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 tickLower,
        int24 tickUpper,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external lock returns (uint128 amount0, uint128 amount1) {
        Position.Info storage position = positions.get(msg.sender, tickLower, tickUpper);

        //If amount0 requested is greater than what is owed, return what is owned
        amount0 = amount0Requested > position.tokensOwed0 ? position.tokensOwed0 : amount0Requested;
        amount1 = amount1Requested > position.tokensOwed1 ? position.tokensOwed1 : amount1Requested;

        //send the tokens
        if (amount0 > 0) {
            position.tokenOwed -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }

        if (amount1 > 0) {
            position.token1Owed -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }

        emit Collect(msg.sender, recipient, tickLower, tickUpper, amount0, amount1);
    }

    function increaseObservationCardinalityNext(uint16 observationCardinalityNext) external lock {
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);
        slot0.observationCardinalityNext = observationCardinalityNextNew;
        //emit event if only both are different
        if (observationCardinalityNextOld != observationCardinalityNextNew) {
            emit ObservationcardinalityIncreased(observationCardinalityNextOld, observationCardinalityNextNew);
        }
    }

    /////////////////////////////////
    //Swap Functions////////////////
    ////////////////////////////////

    struct SwapCache {
        // the protocol fee for the input token
        uint8 feeProtocol;
        // liquidity at the beginning of the swap
        uint128 liquidityStart;
        // the timestamp of the current block
        uint32 blockTimestamp;
        // the current value of the tick accumulator, computed only if we cross an initialized tick
        int56 tickCumulative;
        // the current value of seconds per liquidity accumulator, computed only if we cross an initialized tick
        uint160 secondsPerLiquidityCumulativeX128;
        // whether we've computed and cached the above two accumulators
        bool computedLatestObservation;
    }

    // the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        // the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        // the amount already swapped out/in of the output/input asset
        int256 amountCalculated;
        // current sqrt(price)
        uint160 sqrtPriceX96;
        // the tick associated with the current price
        int24 tick;
        // the global fee growth of the input token
        uint256 feeGrowthGlobalX128;
        // amount of input token paid as protocol fee
        uint128 protocolFee;
        // the current liquidity in range
        uint128 liquidity;
    }

    struct StepComputations {
        // the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        // the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        // whether tickNext is initialized or not
        bool initialized;
        // sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        // how much is being swapped in in this step
        uint256 amountIn;
        // how much is being swapped out
        uint256 amountOut;
        // how much fee is being paid in
        uint256 feeAmount;
    }

    //function

    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external noDelegateCall returns (int256 amount0, int256 amount1) {
        if (amountSpecified == 0) revert ZeroValue();

        //get the initial slot0 struct value also to save gas
        Slot0 memory slot0Start;

        //check if the pool is locked.
        if (slot0Start.unlocked != true) revert PoolLocked();

        //check slippage price
        /**
         * recall that Price = token1/token0, token1 is directly proportional to price and token0 is inversely
         *  so if zeroForOne = true, means that we are selling token0 and buying token1, so token0 price goes down since more tokens are added into the system, so because price = token1/token0, as token0 goes down
         */
        require(
            zeroForOne
                ? sqrtPriceLimitX96 < slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 > TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 > slot0Start.sqrtPriceX96 && sqrtPriceLimitX96 < TickMath.MAX_SQRT_RATIO
        );

        //To enforce reentrancy protection
        slot0.unlocked = false;

        SwapCache memory cache = SwapCache({
            liquidityStart: liquidity,
            blockTimestamp: _blockTimestamp(),
            feeProtocol: zeroForOne ? (slot0Start.feeProtocol % 16) : (slot0Start.feeProtocol >> 4),
            secondsPerLiquidityCumulativeX128: 0,
            tickCumulative: 0,
            computedLatestObservation: false
        });

        //if the amountSpecified is >0, it means that the user specified the specific amount of inout they willing to put in the system, when the amount specified is <0, it means that the user specified the exactOutput that is the amount they want to receive after the swap.
        bool exactInput = amountSpecified > 0;

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0Start.sqrtPriceX96,
            tick: slot0Start.tick,
            feeGrowthGlobalX128: zeroForOne ? feeGrowthGlobal0X128 : feeGrowthGlobal1X128,
            protocolFee: 0,
            liquidity: cache.liquidityStart
        });

        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != state.sqrtPriceLimitX96) {
            //initialize step computations
            StepComputations memory step;

            //set up the price start for the step
            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            (step.tickNext, step.initialized) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, tickSpacing, zeroForOne);

            //to stop our tick from going crazy
            if (step.tickNext < TickMath.MIN_TICK) {
                step.tickNext = TickMath.MIN_TICK;
            } else if (step.tickNext > TickMath.MAX_TICK) {
                step.tickNext = TickMath.MAX_TICK;
            }

            //let us get the price for the next tick as well
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            (state.sqrtPriceX96, step.amountIn, step.amountOut, step.feeAmount) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining,
                fee
            );

            if (exactInput) {
                state.amountSpecifiedRemaining -= (step.amountIn + step.feeAmount).toInt256();
                state.amountCalculated = state.amountCalculated.sub(step.amountOut.toInt256());
            } else {
                state.amountSpecifiedRemaining += step.amountOut.toInt256();
                state.amountCalculated = state.amountCalculated.add((step.amountIn + step.feeAmount).toInt256());
            }

            if (cache.feeProtocol > 0) {
                uint256 delta = step.feeAmount / cache.feeProtocol;
                step.feeAmount -= delta;
                state.protocolFee += uint128(delta);
            }

            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += FullMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }

            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    // check for the placeholder value, which we replace with the actual value the first time the swap
                    // crosses an initialized tick
                    if (!cache.computedLatestObservation) {
                        (cache.tickCumulative, cache.secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                            cache.blockTimestamp,
                            0,
                            slot0Start.tick,
                            slot0Start.observationIndex,
                            cache.liquidityStart,
                            slot0Start.observationCardinality
                        );
                        cache.computedLatestObservation = true;
                    }
                    int128 liquidityNet = ticks.cross(
                        step.tickNext,
                        (zeroForOne ? state.feeGrowthGlobalX128 : feeGrowthGlobal0X128),
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128),
                        cache.secondsPerLiquidityCumulativeX128,
                        cache.tickCumulative,
                        cache.blockTimestamp
                    );
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    if (zeroForOne) liquidityNet = -liquidityNet;

                    state.liquidity = LiquidityMath.addDelta(state.liquidity, liquidityNet);
                }

                state.tick = zeroForOne ? step.tickNext - 1 : step.tickNext;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        // update tick and write an oracle entry if the tick change
        if (state.tick != slot0Start.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0Start.observationIndex,
                cache.blockTimestamp,
                slot0Start.tick,
                cache.liquidityStart,
                slot0Start.observationCardinality,
                slot0Start.observationCardinalityNext
            );
            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
                (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            // otherwise just update the price
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }

        // update liquidity if it changed
        if (cache.liquidityStart != state.liquidity) liquidity = state.liquidity;

        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token0 += state.protocolFee;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
            if (state.protocolFee > 0) protocolFees.token1 += state.protocolFee;
        }

        if (zeroForOne) {
            if (amount1 < 0) TransferHelper.safeTransfer(token1, recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance0Before.add(uint256(amount0)) <= balance0(), "IIA");
        } else {
            if (amount0 < 0) TransferHelper.safeTransfer(token0, recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            require(balance1Before.add(uint256(amount1)) <= balance1(), "IIA");
        }
    }

    function flash(address recipient, uint256 amount0, uint256 amount1, bytes calldata data)
        external
        lock
        noDelegateCall
    {
        uint128 _liquidity = liquidity;
        require(_liquidity > 0, "L");

        uint256 fee0 = FullMath.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = FullMath.mulDivRoundingUp(amount1, fee, 1e6);
        uint256 balance0Before = balance0();
        uint256 balance1Before = balance1();

        if (amount0 > 0) TransferHelper.safeTransfer(token0, recipient, amount0);
        if (amount1 > 0) TransferHelper.safeTransfer(token1, recipient, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        uint256 balance0After = balance0();
        uint256 balance1After = balance1();

        require(balance0Before.add(fee0) <= balance0After, "F0");
        require(balance1Before.add(fee1) <= balance1After, "F1");

        // sub is safe because we know balanceAfter is gt balanceBefore by at least fee
        uint256 paid0 = balance0After - balance0Before;
        uint256 paid1 = balance1After - balance1Before;

        if (paid0 > 0) {
            uint8 feeProtocol0 = slot0.feeProtocol % 16;
            uint256 fees0 = feeProtocol0 == 0 ? 0 : paid0 / feeProtocol0;
            if (uint128(fees0) > 0) protocolFees.token0 += uint128(fees0);
            feeGrowthGlobal0X128 += FullMath.mulDiv(paid0 - fees0, FixedPoint128.Q128, _liquidity);
        }
        if (paid1 > 0) {
            uint8 feeProtocol1 = slot0.feeProtocol >> 4;
            uint256 fees1 = feeProtocol1 == 0 ? 0 : paid1 / feeProtocol1;
            if (uint128(fees1) > 0) protocolFees.token1 += uint128(fees1);
            feeGrowthGlobal1X128 += FullMath.mulDiv(paid1 - fees1, FixedPoint128.Q128, _liquidity);
        }

        emit Flash(msg.sender, recipient, amount0, amount1, paid0, paid1);
    }

    /////////////////////////////////
    //Internal Functions/////////////
    ////////////////////////////////

    function _modifyPosition(ModifyPositionParams memory params)
        public
        returns (Position.Info memory position, int256 amount0, int256 amount1)
    {
        //validate inputs
        checkTicks(params.tickLower, params.tickUpper);
        //initialize the slot0
        Slot0 memory slot0;

        //After this point, we would have basically created our position, flipped our upper or lower ticks if neccessary, update the given tick parameters incase for crossing. and for burning we have deleted the tick details if the tick liquidity goes to zero.
        position = _updatePosition(params.owner, params.tickLower, params.tickUpper, params.liquidityDelta, slot0.tick);

        if (params.liquidityDelta != 0) {
            if (slot0.tick < params.tickLower) {
                amount0 = SqrtPriceMath.getAmount0Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            } else if (slot0.tick < params.tickUpper) {
                uint128 liquidityBefore = liquidity;
                (slot0.observationIndex, slot0.observationCardinality) = observations.write(
                    slot0.observationIndex,
                    _blockTimestamp(),
                    slot0.tick,
                    liquidityBefore,
                    slot0.observationCardinality,
                    slot0.observationCardinalityNext
                );

                amount0 = SqrtPriceMath.getAmount0Delta(
                    slot0.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.tickUpper), params.liquidityDelta
                );
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower), slot0.sqrtPriceX96, params.liquidityDelta
                );

                liquidity = LiquidityMath.addDelta(liquidityBefore, params.liquidityDelta);
            } else {
                amount1 = SqrtPriceMath.getAmount1Delta(
                    TickMath.getSqrtRatioAtTick(params.tickLower),
                    TickMath.getSqrtRatioAtTick(params.tickUpper),
                    params.liquidityDelta
                );
            }
        }
    }

    function _updatePosition(address owner, int24 tickLower, int24 tickUpper, int128 liquidityDelta, int24 tick)
        private
        returns (Position.Info storage position)
    {
        position = positions.get(owner, tickLower, tickUpper);

        //to optimize for gas, we SLOAD it from the storage to memory
        uint256 _feeGrowthGlobal0X128 = feeGrowthGlobal0X128;
        uint256 _feeGrowthGlobal1X128 = feeGrowthGlobal1X128;

        //let us update the ticks
        bool flippedLower;
        bool flippedUpper;

        if (liquidityDelta != 0) {
            uint32 time = _blockTimestamp();
            (int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128) = observations.observeSingle(
                time, 0, slot0.tick, slot0.observationIndex, liquidity, slot0.observationCardinality
            );

            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                false,
                maxLiquidityPerTick
            );

            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                feeGrowthGlobal0X128,
                feeGrowthGlobal1X128,
                secondsPerLiquidityCumulativeX128,
                tickCumulative,
                time,
                true,
                maxLiquidityPerTick
            );

            //so the point of this is that we want to switch the bitmap once we flip. flipping just basically mean we were in zero before and now not in zero, or we were not in zero before but now we are in zero... so whichever we arer flipping 1 or 0...

            if (flippedLower) {
                tickBitmap.flipTick(tickLower, tickSpacing);
            }
            if (flippedUpper) {
                tickBitmap.flipTick(tickUpper, tickSpacing);
            }

            //clear the ticks when not needed w when we burn, since any flip that happen here is because we went to zero when we burn.
            if (liquidityDelta < 0) {
                if (flippedLower) {
                    ticks.clear(tickLower);
                }
                if (flippedUpper) {
                    ticks.clear(tickUpper);
                }
            }
        }

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            ticks.getFeeGrowthInside(tickLower, tickUpper, tick, _feeGrowthGlobal0X128, _feeGrowthGlobal1X128);

        position.update(liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);
    }

    ///////////////////////////////////////
    //////Owner Only Functions////////////
    //////////////////////////////////////

    function setFeeProtocol(uint8 feeProtocol0, uint8 feeProtocol1) external lock onlyFactoryOwner {
        require(
            (feeProtocol0 == 0 || (feeProtocol0 >= 4 && feeProtocol1 <= 10))
                && (feeProtocol1 == 0 || (feeProtocol1 >= 4 && feeProtocol1 <= 10))
        );

        uint8 feeProtocolOld = slot0.feeProtocol;

        //put the fee in fixed point of X4
        slot0.feeProtocol = feeProtocol0 + (feeProtocol1 << 4);

        //for the emission, because we set feeProtocol0 as normal in addition to feeProtocol1X16, to get feeProtocolOld1 we just have to find the remainder when you shift rigt the main feeProtocolOld.
        emit SetFeeProtocol(feeProtocolOld % 16, feeProtocolOld >> 4, feeProtocol0, feeProtocol1);
    }

    function collectProtocol(address recipient, uint128 amount0Requested, uint128 amount1Requested)
        external
        lock
        onlyFactoryOwner
        returns (uint128 amount0, uint128 amount1)
    {
        amount0 = amount0Requested > protocolFees.token0 ? protocolFees.token0 : amount0Requested;
        amount1 = amount1Requested > protocolFees.token1 ? protocolFees.token1 : amount1Requested;

        if (amount0 > 0) {
            if (amount0 == protocolFees.token0) amount0--; //You cannot withdraw all, so we always only edit storage
            protocolFees.token0 -= amount0;
            TransferHelper.safeTransfer(token0, recipient, amount0);
        }
        if (amount1 > 0) {
            if (amount1 == protocolFees.token1) amount1--; //You cannot withdraw all, so we always only edit storage
            protocolFees.token1 -= amount1;
            TransferHelper.safeTransfer(token1, recipient, amount1);
        }
    }
}
