// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {TickMath} from "./TickMath.sol";
import {safeCast} from "./safeCast.sol";
import {LowGasSafeMath} from "./LowGasSafeMath.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

library Tick {
    using LowGasSafeMath for int256;
    using safeCast for int256;

    struct Info {
        // the total position liquidity that references this tick
        uint128 liquidityGross;
        // amount of net liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;
        // fee growth per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint256 feeGrowthOutside0X128;
        uint256 feeGrowthOutside1X128;
        // the cumulative tick value on the other side of the tick
        int56 tickCumulativeOutside;
        // the seconds per unit of liquidity on the _other_ side of this tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint160 secondsPerLiquidityOutsideX128;
        // the seconds spent on the other side of the tick (relative to the current tick)
        // only has relative meaning, not absolute — the value depends on when the tick is initialized
        uint32 secondsOutside;
        // true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        // these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        /**
         * in this function we are looking for the max liquidity a tick can hold without overflowing.. so if total liquidity can be 2^128
         */
        int24 minTick = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;

        //here we calculate the total tick that is possible per tick based on the spacing.
        uint24 numTicks = uint24(((maxTick - minTick) / tickSpacing) + 1);
        //here we divide 2^128 by the numticks gotten
        return type(uint128).max / numTicks;
    }

    function getFeeGrowthInside(
        mapping(int24 => Tick.Info) storage self,
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128
    ) internal view returns (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) {
        /**
         * so in this function we want to return the fee growth rate that is inside a position through the help of the position upper and lower ticks
         */

        //so first of all, let us get the tick details of the upper and lower tick
        Info storage lower = self[tickLower];
        Info storage upper = self[tickUpper];

        //so because
        //feeRateBelowLowerTick +
        //        FeeRateBetweenLowerAndUpperTick(fee inside) + feeRateAboveUpperTick = GlobalFeeRate
        //so feeInside = GlobalFeeRate - feeRateBelowLowerTick - feeRateAboveUpperTick

        //now how do we get the fee inside??

        //let's calculate the fee below the lower tick
        uint256 feeGrowthBelow0X128;
        uint256 feeGrowthBelow1X128;

        if (tickCurrent >= tickLower) {
            //so at this point we have obviously updated the lowerTick feeGrowthOutsideX128
            //we can just make it equal to it
            feeGrowthBelow0X128 = lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = lower.feeGrowthOutside1X128;
        } else {
            //if the lower tick has never been reached, then it make sense for it to be the globalFeeRate
            feeGrowthBelow0X128 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
            feeGrowthBelow1X128 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
        }

        //How about upper??
        uint256 feeGrowthAbove0X128;
        uint256 feeGrowthAbove1X128;

        if (tickCurrent < tickUpper) {
            feeGrowthAbove0X128 = upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = upper.feeGrowthOutside1X128;
        } else {
            feeGrowthAbove0X128 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
            feeGrowthAbove1X128 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
        }

        //Now using the formular we describe above, use it to calculate the feeRate inside
        feeGrowthInside0X128 = feeGrowthGlobal0X128 - feeGrowthBelow0X128 - feeGrowthAbove0X128;
        feeGrowthInside1X128 = feeGrowthGlobal1X128 - feeGrowthBelow1X128 - feeGrowthAbove1X128;
    }

    function update(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Tick.Info storage info = self[tick];
        uint128 liquidityGrossBefore = info.liquidityGross;
        //add the new token liquidity to form this liquidity
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(liquidityGrossBefore, liquidityDelta);
        //make sure that the liquidity is less the maxLiquidity
        require(liquidityGrossAfter <= maxLiquidity, "LO");

        //in other to check if liquidity was added to the pool from zero or liquidity was removed from the pool completely, we use this to check so we can update the bitmap.
        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            //it make sense that when the liquidity gross is empty and the tick is not up to the current tick, that is when the other part of the tick properties should be updated.
            if (tick <= tickCurrent) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
                info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128;
                info.tickCumulativeOutside = tickCumulative;
                info.secondsOutside = time;
            }
            info.initialized = true;
        }

        //time to update the liquidity gross which was the main thing we came here to do
        info.liquidityGross = liquidityGrossAfter;

        //also we have to update the liquiditynet for when we cross the pool

        info.liquidityNet = upper
            ? int256(info.liquidityNet).sub(liquidityDelta).toInt128()
            : int256(info.liquidityNet).add(liquidityDelta).toInt128();
    }

    //use telete the tick
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick) internal {
        delete self[tick];
    }

    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint256 feeGrowthGlobal0X128,
        uint256 feeGrowthGlobal1X128,
        uint160 secondsPerLiquidityCumulativeX128,
        int56 tickCumulative,
        uint32 time
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];
        info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
        info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        info.secondsPerLiquidityOutsideX128 = secondsPerLiquidityCumulativeX128 - info.secondsPerLiquidityOutsideX128;
        info.tickCumulativeOutside = tickCumulative - info.tickCumulativeOutside;
        info.secondsOutside = time - info.secondsOutside;
        liquidityNet = info.liquidityNet;
    }
}
