// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {EmptyMarketInvariantTest, LocalInvariantTest} from "./LocalInvariant.t.sol";
import {LocalRouterHandler} from "./LocalRouterHandler.sol";
import {V3EmptyMarketHandler, V3Handler} from "./V3Handler.sol";

/// @notice The core and the real UniswapV3Adapter on a real Uniswap v3 pool, WETH its token0
contract V3InvariantTest is LocalInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V3Handler(true);
    }

    /// @notice Donate into the adapter's shared range -> swaps earn fees -> collectFees -> open -> checkAdapterBalances
    function test_donateThenSwapsThenCollectFeesLeavesNothingInAdapter() public {
        handler.open(0, 3, 1e13, true); // range 3 (one of the ranges `donate` mints into)
        handler.donate(0, 1e11);
        assertGt(V3Handler(address(handler)).donated(3), 0, "donated into range 3");
        // Move pool price across range 3 and back so donated + position liquidity both earn fees
        for (uint256 i; i < 6; ++i) {
            handler.swap(false, 50_000e6);
            handler.swap(true, 25e18);
        }
        handler.collectFees(0, 0);
        handler.checkAdapterBalances();
        handler.open(1, 3, 1e12, false);
        handler.checkAll();
        handler.unwindAll();
    }
}

/// @notice The same with USDC as the pool's token0
contract V3InvariantUsdcToken0Test is LocalInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V3Handler(false);
    }
}

/// @notice Cold-start empty-market mode on the real Uniswap v3 pool
contract V3EmptyMarketInvariantTest is EmptyMarketInvariantTest {
    function _newHandler() internal override returns (LocalRouterHandler) {
        return new V3EmptyMarketHandler();
    }
}
