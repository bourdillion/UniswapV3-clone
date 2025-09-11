// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

library TickMath {
    /**
     * the fartest range that the two tokens in a pool max at 2^128, so we want to calculate the range.
     *
     * recall that price(p) = (1.0001)^t
     * where (1.0001)^t is gotten from (1 + 1/10000)^tick
     * so to get t(tick);
     *
     * take the ln of both side
     * ln(p) = ln(1.0001)^t
     *
     * from laws of logarithm lna^b = blna, thus
     * ln(p) = tln(1.0001)
     *
     * make t(tick) subject
     *
     * t = ln(p)/ln(1.0001)
     *
     * but P = 2^128
     * t = ln(2^128)/ln(1.001) = 887272
     *
     * since this is the minimum, we negate it.
     */
    int24 internal constant MIN_TICK = -887272;

    int24 internal constant MAX_TICK = 887272;

    /**
     * this is the minSqrtRatio our min tick can ever reach
     * This min_tick is -887272
     *
     * recall that sqrtPrice is given as
     * sqrtP = sqrt(1.0001^t)
     * sqrtP = (1.0001^(t/2))
     * but t =-887272
     * sqrtP = (1.0001^-887272/2)
     * sqrtP = 5.4212 x 10^-20
     *
     * but how do we store this number in solidity???
     * we convert it to fixed point number(Q64.96) and store in 2^96. i.e
     *
     * 5.4212 x 10^-20 x 2^96
     * = 4295128738
     *
     */
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;

    //same formular above but with +887272
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    function getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        /**
         * first let us find the absolute number of the tick.
         * but why absolute tick, since tick can be negative??
         * because the hex is precomputed as the negative tick, to avoid sign comfusion to get our positive number back - we get the reciporocal of the sqrtprice
         */
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        //obviously it make sense not to allow the param pass the max tick.
        require(absTick <= uint256(int256(MAX_TICK)), "T");

        /**
         * what we are basically doing here is using bitwise AND to compare the bits of the abstick and 0x1
         * we use binary to find the exponent and multiply it
         * so here it says when you compare, if it isn't 0, it is 1
         *
         * if it is not zero then we do sqrt(1.0001^t), but here the tick is -1, like i said earlier this stuff
         * is precompute as in the negative form.
         * while, if it is equals to zero, we just return 2^0 in hex form which is 1 but << 2^128 to store it in the
         * Q128.128 form.
         */
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        //now we compute step by step using binary to compute the exponent till we get it., but why 20 times?
        //here we are comparing if absTick is 1 in the second to the last bit or not, if it is we multiply by our previos ratio
        //because we are multiplying a fixed point number with another fixed point number, we have to divide them by the based denominator
        //which make sense to be 128... from then on using exponents, we multiply the ratio when the bit is 1 at that position and jump through
        //the zeros...just like that

        /**
         * we have up to 20 conditional because that is the max binary of our max tick
         * if we convert 887272 to binary we get 1101 1000 1001 1110 1000
         * which is 20 bits long.
         *
         */
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128; // we have 0x2 because 2^1 = 2
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128; // we have 0x4 because 2^2 = 4
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128; // we have 0x8 because 2^3 = 8
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128; // we have 0x10 because 2^4 = 16
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128; //and so on...
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        //because we used minus to precompute the price hex, it make sense to find the reciporocal for the positive ones
        //but the solidity doesnt allow decimal because 1/ratio(a big decimal) ... doesn't work
        //so uniswap then use a rather big number to divide it
        // if you use    1 x 2^256-1
        //               ------------- = 1 x 2^128/y
        //                y x 2^128

        //that will give us a large number in fixed point Q128.128 but more precise and works with solidity, reason we use
        //type(uint256).max
        if (tick > 0) ratio = type(uint256).max / ratio;

        /**
         * here because we want to convert our Q128.128 fps to Q63.96 because that is the fpN for sqrtPriceX96
         * we first take out the extra 32 by >>32
         * if there is a decimal in the last 32 bits we want to remove, we round it up to 1, and if not we
         * leave it as it is.
         */
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }

    function getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick) {
        //here we are just making sure that the sqrtPriceX96 is within bound
        require(sqrtPriceX96 >= MIN_SQRT_RATIO && sqrtPriceX96 < MAX_SQRT_RATIO, "R");

        //we are bumbing the sqrtPricex96 to 128
        uint256 ratio = uint256(sqrtPriceX96) << 32;

        /**
         * so here we are findind the most significant bit
         * the method employed to find it is the divide and conquer method, we divide the exponent of 2 consistently
         * till we get to 1, we start from 128 because 2^128 + 2^64 + 2^32 + 2^16 + 2^8 + 2^4 + 2^2 + 2^1 = 2^255
         * so  the sequence of events are;
         * 1. we compare r(sqrtPrice) and 2^128-1 to see which is greater
         * 2. if r is greater it returns 1 and 0 if r is lesser than that number
         * 3. next we shiftleft 0 or 1 with 7 times, that is basically multiplying them by 7 0's
         * 4. if we assume that we got 1, and it is now 10000000 for exammple, we add our new number to msb, and removing that number from our r
         *
         * so for example if our number when computed in dec is 140
         * next we basically do 140 > 128? 1 : 0
         * next we add that 128 to msb - we are basically saying our msb is definitely not at position 7 or it has value > 2^128
         * lastly we remove that 128 from r, so 140 - 128 = 12; so with our new r and msb we go to the next step - until we have cut out the whole position to be left with just the msb.
         */
        uint256 r = ratio;
        uint256 msb = 0;

        assembly {
            let f := shl(7, gt(r, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(6, gt(r, 0xFFFFFFFFFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(5, gt(r, 0xFFFFFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(4, gt(r, 0xFFFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(3, gt(r, 0xFF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(2, gt(r, 0xF))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := shl(1, gt(r, 0x3))
            msb := or(msb, f)
            r := shr(f, r)
        }
        assembly {
            let f := gt(r, 0x1)
            msb := or(msb, f)
        }
    }
}
