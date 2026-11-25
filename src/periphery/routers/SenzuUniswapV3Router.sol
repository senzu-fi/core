// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PoolAddress} from "../../libraries/uniswap/PoolAddress.sol";
import {SenzuV3PathRouter} from "./SenzuV3PathRouter.sol";

/**
 *  @title  SenzuUniswapV3Router
 *  @notice SenzuBaseRouter swapping in Uniswap v3 pools. Route: Uniswap's packed path, tokenIn first in both
 *          directions (tokenIn, fee, token, fee, ..., tokenOut; 20-byte tokens, 3-byte fees).
 */
contract SenzuUniswapV3Router is SenzuV3PathRouter {
    /// @notice Uniswap v3 factory
    address public immutable factory;

    constructor(address collateral_, address weth_, address factory_, address pyth_)
        SenzuV3PathRouter(collateral_, weth_, pyth_)
    {
        factory = factory_;
    }

    function _poolOf(address a, address b, uint24 fee) internal view override returns (address) {
        (address token0, address token1) = a < b ? (a, b) : (b, a);
        return PoolAddress.compute(factory, token0, token1, fee);
    }
}
