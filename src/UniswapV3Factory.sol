//SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {UniswapV3PoolDeployer} from "./UniswapV3PoolDeployer.sol";

contract UniswapV3Factory is UniswapV3PoolDeployer {
    //error
    error SameToken(address tokenA, address tokenB);
    error address0();
    error InvalidFee(uint24 fee);
    error PoolAlreadyExists(address poolAddress);
    error InvalidAuth();

    //events
    event PoolCreated(address indexed token0, address indexed token1, uint24 fee, address indexed pool);
    event OwnerChanged(address indexed owner);

    //states
    mapping(uint24 fee => uint24 tickSpacing) public feeAmountTickSpacing;
    address public owner;
    mapping(address => mapping(address => mapping(uint24 => address poolAddress))) public getPool;

    constructor() {
        owner = msg.sender;

        //set up the three fee tier
        feeAmountTickSpacing[500] = 10;
        feeAmountTickSpacing[3000] = 60;
        feeAmountTickSpacing[10000] = 200;
    }

    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool) {
        //first let's check that both token are not the same
        if (tokenA == tokenB) {
            revert SameToken(tokenA, tokenB);
        }

        //Next sort the tokens
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        //check the token that the tokens were properly sorted and address(0) was not entered as a parameter
        if (token0 == address(0) || token1 == address(0)) {
            revert address0();
        }

        //check that the fee is right
        uint24 tickSpacing = feeAmountTickSpacing[fee];
        if (tickSpacing == 0) {
            revert InvalidFee(fee);
        }

        //check that this pool don't already exist
        if (getPool[token0][token1][fee] != address(0)) {
            revert PoolAlreadyExists(getPool[token0][token1][fee]);
        }

        //deploy the pool
        pool = deploy(address(this), token0, token1, fee, tickSpacing);

        //fix the mapping in both direction of token
        getPool[token0][token1][fee] = pool;
        getPool[token1][token0][fee] = pool;

        //emit event
        emit PoolCreated(token0, token1, fee, pool);
    }

    function changeOwner(address _owner) external {
        if (msg.sender != owner) {
            revert InvalidAuth();
        }

        if (_owner == address(0)) {
            revert address0();
        }

        owner = _owner;

        emit OwnerChanged(owner);
    }

    function enableFeeAmount() external {}
}
