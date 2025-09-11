// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library LiquidityMath {
    function addDelta(uint128 x, int128 y) internal pure returns (uint128 z) {
        /**
         * so because we are adding an int128 to a uint128 to get a uint128 final value, this library wad formed.
         *
         * we check if the int value is negative, and if it is then minus it from the main uint, means we are probably burning liquidity from this tick position. if it is not negative then we add it normally.
         */
        if (y < 0) {
            require((z = x - uint128(-y)) < x, "LS");
        } else {
            require((z = x + uint128(y)) >= x, "LA");
        }
    }
}
