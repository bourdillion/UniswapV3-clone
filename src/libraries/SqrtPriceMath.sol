// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {safeCast} from "./safeCast.sol";
import {FullMath} from "./FullMath.sol";
import {LowGasSafeMath} from "./LowGasSafeMath.sol";
import {FixedPoint96} from "./FixedPoint96.sol";
import {UnsafeMath} from "./UnsafeMath.sol";

library SqrtPriceMath {
    using LowGasSafeMath for uint256;
    using safeCast for uint256;

    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        return liquidity < 0
            ? -getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, false).toInt256()
            : getAmount0Delta(sqrtRatioAX96, sqrtRatioBX96, liquidity, true).toInt256();
    }

    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity)
        internal
        pure
        returns (int256 amount0)
    {
        return liquidity < 0
            ? -getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint256(int256(liquidity)), false).toInt256()
            : getAmount1Delta(sqrtRatioAX96, sqrtRatioBX96, uint256(int256(liquidity)), true).toInt256();
    }

    function getAmount0Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, int128 liquidity, bool roundingUp)
        public
        pure
        returns (uint256 amount0)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        //liquidity is made to X96
        uint256 numerator1 = uint256(int256(liquidity)) << FixedPoint96.RESOLUTION;
        //get the difference between the ratio of both tick
        uint256 numerator2 = sqrtRatioBX96 - sqrtRatioAX96;

        require(sqrtRatioAX96 > 0);

        //so we are basically doing   L(numerator1) X [sqrt(p2) - sqrt(p1)]
        //        ---------------------------------------
        //              [sqrt(p2) X sqrt(p1)]

        //how did we get this formular?? stay with me
        //recall that x.y = k and p = y/x
        //thus y = k/x, subtitute into p = y/x
        //p = k/x^2
        //but we need x because that is the amount we are looking for, so solving for x we have
        //x = sqrt(k)/sqrt(p)
        //but recall that k = L^2 = x.y, thus putting L2 for k we have
        //x = L/sqrt(p)

        //so the change of amount between the upper and lower tick is
        //L/sqrt(p2) - L/sqrt(p1), if you take sqrt(p2) X sqrt(p1) as your LCM denominator.
        //you have the formular above
        return roundingUp
            ? UnsafeMath.divRoundingUp(FullMath.mulDivRoundingUp(numerator1, numerator2, sqrtRatioBX96), sqrtRatioAX96)
            : FullMath.mulDiv(numerator1, numerator2, sqrtRatioBX96) / sqrtRatioAX96;
    }

    function getAmount1Delta(uint160 sqrtRatioAX96, uint160 sqrtRatioBX96, uint256 liquidity, bool roundingUp)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtRatioAX96 > sqrtRatioBX96) (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        //this one is straightforward
        //if y = k/x or y = L^2/x
        //but x = L/sqrt(p)
        //solving for y = L^2 / (L/sqrt(p))
        //y = L X sqrt(p)
        //to account for change in price we do y2 - y1 = L(sqrt(p2) - (sqrt(p2))
        //And that is basically what we are doing here.

        return roundingUp
            ? FullMath.mulDivRoundingUp(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96)
            : FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);
    }

    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        if (amount == 0) return sqrtPX96;
        uint256 numerator1 = uint256(liquidity) << FixedPoint96.RESOLUTION;

        if (add) {
            uint256 product;
            if ((product = amount * sqrtPX96) / amount == sqrtPX96) {
                uint256 denominator = numerator1 + product;
                if (
                    denominator >= numerator1
                    // always fits in 160 bits
                ) {
                    return uint160(FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator));
                }
            }

            return uint160(UnsafeMath.divRoundingUp(numerator1, (numerator1 / sqrtPX96).add(amount)));
        } else {
            uint256 product;
            // if the product overflows, we know the denominator underflows
            // in addition, we must check that the denominator does not underflow
            require((product = amount * sqrtPX96) / amount == sqrtPX96 && numerator1 > product);
            uint256 denominator = numerator1 - product;
            return FullMath.mulDivRoundingUp(numerator1, sqrtPX96, denominator).toUint160();
        }
    }

    /// @notice Gets the next sqrt price given a delta of token1
    /// @dev Always rounds down, because in the exact output case (decreasing price) we need to move the price at least
    /// far enough to get the desired output amount, and in the exact input case (increasing price) we need to move the
    /// price less in order to not send too much output.
    /// The formula we compute is within <1 wei of the lossless version: sqrtPX96 +- amount / liquidity
    /// @param sqrtPX96 The starting price, i.e., before accounting for the token1 delta
    /// @param liquidity The amount of usable liquidity
    /// @param amount How much of token1 to add, or remove, from virtual reserves
    /// @param add Whether to add, or remove, the amount of token1
    /// @return The price after adding or removing `amount`
    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPX96, uint128 liquidity, uint256 amount, bool add)
        internal
        pure
        returns (uint160)
    {
        // if we're adding (subtracting), rounding down requires rounding the quotient down (up)
        // in both cases, avoid a mulDiv for most inputs
        if (add) {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? (amount << FixedPoint96.RESOLUTION) / liquidity
                    : FullMath.mulDiv(amount, FixedPoint96.Q96, liquidity));

            return uint256(sqrtPX96).add(quotient).toUint160();
        } else {
            uint256 quotient =
                (amount <= type(uint160).max
                    ? UnsafeMath.divRoundingUp(amount << FixedPoint96.RESOLUTION, liquidity)
                    : FullMath.mulDivRoundingUp(amount, FixedPoint96.Q96, liquidity));

            require(sqrtPX96 > quotient);
            // always fits 160 bits
            return uint160(sqrtPX96 - quotient);
        }
    }

    /// @notice Gets the next sqrt price given an input amount of token0 or token1
    /// @dev Throws if price or liquidity are 0, or if the next price is out of bounds
    /// @param sqrtPX96 The starting price, i.e., before accounting for the input amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountIn How much of token0, or token1, is being swapped in
    /// @param zeroForOne Whether the amount in is token0 or token1
    /// @return sqrtQX96 The price after adding the input amount to token0 or token1
    function getNextSqrtPriceFromInput(uint160 sqrtPX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // round to make sure that we don't pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountIn, true)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountIn, true);
    }

    /// @notice Gets the next sqrt price given an output amount of token0 or token1
    /// @dev Throws if price or liquidity are 0 or the next price is out of bounds
    /// @param sqrtPX96 The starting price before accounting for the output amount
    /// @param liquidity The amount of usable liquidity
    /// @param amountOut How much of token0, or token1, is being swapped out
    /// @param zeroForOne Whether the amount out is token0 or token1
    /// @return sqrtQX96 The price after removing the output amount of token0 or token1
    function getNextSqrtPriceFromOutput(uint160 sqrtPX96, uint128 liquidity, uint256 amountOut, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtQX96)
    {
        require(sqrtPX96 > 0);
        require(liquidity > 0);

        // round to make sure that we pass the target price
        return zeroForOne
            ? getNextSqrtPriceFromAmount1RoundingDown(sqrtPX96, liquidity, amountOut, false)
            : getNextSqrtPriceFromAmount0RoundingUp(sqrtPX96, liquidity, amountOut, false);
    }
}

