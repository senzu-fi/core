// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuUniswapV3Router} from "../../src/periphery/routers/SenzuUniswapV3Router.sol";
import {SenzuUniswapV4Router} from "../../src/periphery/routers/SenzuUniswapV4Router.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev The v3 router's swaps on their own, from and to its balance: what one swap gives (exactIn) or costs (exactOut)
contract V3RouterHarness is SenzuUniswapV3Router {
    constructor(address collateral_, address weth_, address factory_)
        SenzuUniswapV3Router(collateral_, weth_, factory_, address(0))
    {}

    function exactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route)
        external
        returns (uint256 got)
    {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        _swapExactIn(tokenIn, tokenOut, amountIn, route);
        got = IERC20(tokenOut).balanceOf(address(this)) - before;
    }

    function exactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory route)
        external
        returns (uint256 spent)
    {
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        _swapExactOut(tokenIn, tokenOut, amountOut, route);
        spent = before - IERC20(tokenIn).balanceOf(address(this));
    }
}

/// @dev The v4 router's swaps on their own, as V3RouterHarness
contract V4RouterHarness is SenzuUniswapV4Router {
    constructor(address collateral_, address weth_, address poolManager_)
        SenzuUniswapV4Router(collateral_, weth_, poolManager_, address(0))
    {}

    function exactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route)
        external
        returns (uint256 got)
    {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        _swapExactIn(tokenIn, tokenOut, amountIn, route);
        got = IERC20(tokenOut).balanceOf(address(this)) - before;
    }

    function exactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory route)
        external
        returns (uint256 spent)
    {
        uint256 before = IERC20(tokenIn).balanceOf(address(this));
        _swapExactOut(tokenIn, tokenOut, amountOut, route);
        spent = before - IERC20(tokenIn).balanceOf(address(this));
    }
}
