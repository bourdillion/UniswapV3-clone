// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {FixedPoint128} from "./FixedPoint128.sol";
import {FullMath} from "./FullMath.sol";
import {LiquidityMath} from "./LiquidityMath.sol";

library Position {
    struct Info {
        uint128 liquidityDelta;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokenOwed0;
        uint128 tokenOwed1;
    }

    function get(mapping(bytes32 => Info) storage self, address owner, int24 tickLower, int24 tickUpper)
        public
        view
        returns (Position.Info storage position)
    {
        position = self[keccak256(abi.encodePacked(owner, tickLower, tickUpper))];
    }

    function update(
        Info storage self,
        int128 liquidityDelta,
        uint256 feeGrowthInside0X128,
        uint256 feeGrowthInside1X128
    ) internal {
        Info memory _self = self;

        uint128 liquidityNext;
        if (liquidityDelta == 0) {
            require(_self.liquidityDelta > 0, "NP"); // disallow pokes for 0 liquidity positions
            liquidityNext = _self.liquidityDelta;
        } else {
            liquidityNext = LiquidityMath.addDelta(_self.liquidityDelta, liquidityDelta);
        }

        // calculate accumulated fees
        uint128 tokensOwed0 = uint128(
            FullMath.mulDiv(
                feeGrowthInside0X128 - _self.feeGrowthInside0LastX128, _self.liquidityDelta, FixedPoint128.Q128
            )
        );
        uint128 tokensOwed1 = uint128(
            FullMath.mulDiv(
                feeGrowthInside1X128 - _self.feeGrowthInside1LastX128, _self.liquidityDelta, FixedPoint128.Q128
            )
        );

        // update the position
        if (liquidityDelta != 0) self.liquidityDelta = liquidityNext;
        self.feeGrowthInside0LastX128 = feeGrowthInside0X128;
        self.feeGrowthInside1LastX128 = feeGrowthInside1X128;
        if (tokensOwed0 > 0 || tokensOwed1 > 0) {
            // overflow is acceptable, have to withdraw before you hit type(uint128).max fees
            self.tokenOwed0 += tokensOwed0;
            self.tokenOwed1 += tokensOwed1;
        }
    }
}
