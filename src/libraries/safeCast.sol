// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library safeCast {
    function toUint160(uint256 x) internal pure returns (uint160 y) {
        require((y = uint160(x)) == x);
    }

    function toInt128(int256 x) internal pure returns (int128 y) {
        require((y = int128(x)) == x);
    }

    function toInt256(uint256 x) internal pure returns (int256 y) {
        require(x <= type(uint256).max);
        y = int256(x);
    }
}
