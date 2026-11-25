// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {EmptyMarketInvariantTest, LocalInvariantTest} from "./LocalInvariant.t.sol";
import {LocalRouterHandler} from "./LocalRouterHandler.sol";
import {V4EmptyMarketHandler, V4Handler} from "./V4Handler.sol";

/// @notice The core and the real UniswapV4Adapter on Uniswap v4's real PoolManager: the native ETH/USDC pool
contract V4InvariantTest is LocalInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V4Handler(true);
    }
}

/// @notice The same on a WETH/USDC pool of two ERC-20s, USDC its currency0
contract V4InvariantErc20Test is LocalInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V4Handler(false);
    }
}

/// @notice Cold-start empty-market mode on the real Uniswap v4 PoolManager
contract V4EmptyMarketInvariantTest is EmptyMarketInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V4EmptyMarketHandler();
    }
}
