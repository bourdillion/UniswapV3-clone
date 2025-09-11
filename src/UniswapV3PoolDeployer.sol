//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UniswapV3Pool} from "./UniswapV3Pool.sol";

contract UniswapV3PoolDeployer {
    struct Parameters {
        address factory;
        address token0;
        address token1;
        uint24 fee;
        uint24 tickSpacing;
    }

    Parameters public parameters;

    function deploy(address factory, address token0, address token1, uint24 fee, uint24 tickSpacing)
        public
        returns (address poolAddress)
    {
        //initialize the parameter variable
        parameters = Parameters({factory: factory, token0: token0, token1: token1, fee: fee, tickSpacing: tickSpacing});
        //use create2 to create a new pool, anytime we add a salt in between we automatically use create2 opcode
        poolAddress = address(new UniswapV3Pool{salt: keccak256(abi.encode(token0, token1, fee))}());
        //we delete the parameter value as it is just acting as a transient storage.
        delete parameters;
    }
}
