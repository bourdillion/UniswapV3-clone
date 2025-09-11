// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {BitMath} from "./BitMath.sol";

library TickBitMap {
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        //here we want to know the word(group of 256) that the tick belong to.
        //for example if the tick is 700, 700/2^8 = 2 drop the remainder
        //this means that the tick is in second group.
        wordPos = int16(tick >> 8);
        //for the bit we are finding where the bit is in the group
        bitPos = uint8(int8(tick % 256));
    }

    function flipTick(mapping(int16 => uint256) storage self, int24 tick, int24 tickSpacing) internal {
        //check if we passed in the right tick and tickSpacing
        require(tick % tickSpacing == 0);
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing);
        //so we want to create a mask so we can use to flip it
        uint256 mask = 1 << bitPos;
        self[wordPos] ^= mask;
    }

    function nextInitializedTickWithinOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte
    ) internal view returns (int24 next, bool initialized) {
        //based on the spacing
        int24 compressed = tick / tickSpacing;
        //to adjust for negative ticks
        if (tick < 0 && tick % tickSpacing != 0) compressed--;

        if (lte) {

            /**
             * so when lte(zeroForOne) we want that only the positions that are less than our tick is acknowledged - so we build a mask that makes all the position after our position zero.
             */

            //we get our position, that is our wordPos and bitPos
            (int16 wordPos, uint8 bitPos) = position(compressed);
            // all the 1s at or to the right of the current bitPos

            /**
             * what are we doing here? we are creating a mask. first off;
             * we shiftleft 1 by our position, so if our position is 10, we do 0x1<<10 = 0x10000000000
             * then we minus 1 from whatever we get, so 0x10000000000 - 1 = 0x01111111111;
             * if you notice when you minus 1, all the lower bit flipped except the first one.
             * now you add the result together, 0x01111111111 + 0x10000000000 = 0x11111111111
             * now do a AND operation between our word gotten and our mask
             * normally a word contains 256 bit but assuming it contain just 16, then it means we are going to pad our mask gotten by 0's, so our mask becomes 0x00000001111111111, 
             * if you are smart you already know 0 AND 1 = 0, that means we have already gotten rid of all the bits before our position, so any of the bit that is 1 after our position are the last one standing - the rest are turned 0.
             */
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the right of or at the current tick, return rightmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick

            /**
             * A continuation of the previous explanation, now we have turned all the bit that are bigger than our bit to 0, to find the next initialized tick, it make sense to find the most significant bit - that is the biggest 1 in the last bit standing. but to get the actuall position we do the remaining shenenagians here. to get our exact tick we multiply by the tickspacing since we compreseed the tick from the onset. if there is no 1 before our position we just return the edge bit.
             */
            next = initialized
                ? (compressed - int24(int256(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                : (compressed - int24(int8(bitPos))) * tickSpacing;
        } else {
            // start from the word of the next tick, since the current tick state doesn't matter
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            // all the 1s at or to the left of the bitPos

            /**
             * fairs, we do almost the same thing as before here,
             * so assuming our bitPos is 10 again, so 1 << 10 = 0x10000000000
             * next 0x100000000000 - 1 = 0x01111111111
             * we find the complement for all so it becomes 0x10000000000
             * so from common sense, since we are only interested for initialized tick that are bigger than bitPos, this just turns the rest bit below bitPos to zero.
             */
            uint256 mask = ~((1 << bitPos) - 1);
            uint256 masked = self[wordPos] & mask;

            // if there are no initialized ticks to the left of the current tick, return leftmost in the word
            initialized = masked != 0;
            // overflow/underflow is possible, but prevented externally by limiting both tickSpacing and tick

            /**
             * Make sense that since our bitPos is the smallest in the list since we are going up, we want the least significant figure that is the smallest 1, because that is the closest to our position. and then all other shenenagians to find the exact position.
             */
            next = initialized
                ? (compressed + 1 + int24(int256(BitMath.leastSignificantBit(masked) - bitPos))) * tickSpacing
                : (compressed + 1 + int24(int8(type(uint8).max - bitPos))) * tickSpacing;
        }
    }
}
