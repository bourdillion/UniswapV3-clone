//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface IUniswapV3PoolDeployer {
    function parameters()
        external
        view
        returns (address factory, address token0, address token1, uint24 fee, int24 tickSpacing);
}
