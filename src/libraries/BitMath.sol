//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library BitMath {
    function mostSignificantBit(uint256 x) internal pure returns (uint256 y) {
        require(x > 0);

        if (x >= 0x100000000000000000000000000000000) {
            //if x >= 2^128, let remove the rightmost 128 digit
            x >>= 128;
            y += 128;
        }
        //so we will move 128>64>32>16>8>4>2 then return y

        // if an hex value is 4 binary value, then 64/4 = 16 zeros
        if (x >= 0x10000000000000000) {
            x >>= 64;
            y += 64;
        }
        //now for 32/4 = 8
        if (x >= 0x100000000) {
            x >>= 32;
            y += 32;
        }
        //now for 16/4 = 4
        if (x >= 0x1000) {
            x >>= 16;
            y += 16;
        }
        //now for 8/4 = 2
        if (x >= 0x100) {
            x >>= 8;
            y += 8;
        }
        //now for 4/4 = 2
        if (x >= 0x10) {
            x >>= 4;
            y += 4;
        }
        //lastly for 2
        if (x >= 0x2) {
            y += 1;
        }
        //so the return value (y) is the position of the most significant bit, thus it is the number position we have removed or shifted away till we get to the most significant bit
    }

    function leastSignificantBit(uint256 x) internal pure returns (uint256 y) {
        require(x > 0);

        y = 255;
        /**
         * so in this function we are looking for the index of the position where the last 1 in the binary of x is(this is LSB), so assuming x = 2^255, we want to use the divide and conquer to get the LSB
         */

        //so since x is type(uint256).max, this bitwise & operator take of the last 2^128 bit of x and check if there is a 1 there, if there is let us remove this number we have checked and if there is not it meants the last 2^128 bit of x is stupid - so we just remove it.

        //normally i show we have to shift left it but then we just want to show it in the return variable
        if (x & type(uint128).max > 0) {
            y -= 128;
        } else {
            x >>= 128;
        }
        //so here we are saying is this LSB in the last 64 bit, if it is minus from, if not shift out the useless zero's
        if (x & type(uint64).max > 0) {
            y -= 64;
        } else {
            x >>= 64;
        }
        //so here we are saying is this LSB in the last 32 bit, if it is minus from, if not shift out the useless zero's
        if (x & type(uint32).max > 0) {
            y -= 32;
        } else {
            x >>= 32;
        }
        //so here we are saying is this LSB in the last 16 bit, if it is minus from, if not shift out the useless zero's
        if (x & type(uint16).max > 0) {
            y -= 16;
        } else {
            x >>= 16;
        }
        //so here we are saying is this LSB in the last 8 bit, if it is minus from, if not shift out the useless zero's
        if (x & type(uint8).max > 0) {
            y -= 8;
        } else {
            x >>= 8;
        }
        //here we are saying is this number in the last 2^4-1=15 = 0xf?
        if (x & 0xf > 0) {
            y -= 4;
        } else {
            x >>= 4;
        }
        //what the last 2^2 - 1 = 3?
        if (x & 0x3 > 0) {
            y -= 2;
        } else {
            x >>= 2;
        }

        if (x & 0x2 > 0) {
            y -= 1;
        }
    }
}
