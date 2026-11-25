// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MockAggregator, MockStock} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";
import {ISenzuOracle} from "src/interfaces/ISenzuOracle.sol";
import {lenderId} from "src/libraries/Types.sol";

/// @notice A stock token in the same deployment as crypto: collateral in an NVDA/USDC
///         position and a market of its own. While the token pauses its price (corporate actions), nothing that needs
///         a price runs, and every way out still works.
contract StockPauseTest is HubFixture {
    MockStock nvda;
    MockAggregator nvdaFeed;
    uint256 stockId; // Carol's NVDA/USDC position, borrowing USDC and NVDA

    function setUp() public override {
        super.setUp();
        nvda = new MockStock("NVDA");
        nvdaFeed = new MockAggregator(8, 180e8);
        oracle.addPausableFeed(address(nvda), address(nvdaFeed), 1 days);
        borrowable.createMarket(address(nvda), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(nvda), 1.33e18, 1.05e18, true); // covers a −25% / +33% gap
        riskConfig.setPairEnabled(address(adapter), address(nvda), address(usdc), true);

        // Bob lends NVDA too
        nvda.mint(BOB, 10_000e18);
        vm.startPrank(BOB);
        nvda.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(nvda), 10_000e18, BOB);
        vm.stopPrank();

        // Carol: a full-range NVDA/USDC position worth about $27k, borrowing $5k of USDC and 10 NVDA (a stock is
        // borrowed only by a position in its own pair)
        bytes memory data =
            abi.encode(address(nvda), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e15));
        vm.startPrank(CAROL);
        (stockId,,,,,) = collateral.open(CAROL, CAROL, data);
        collateral.borrow(CAROL, stockId, address(usdc), 5_000e6, CAROL);
        collateral.borrow(CAROL, stockId, address(nvda), 10e18, CAROL);
        vm.stopPrank();
    }

    /// @dev A stock is owed only by a position in its own pair. Owed by Alice's WETH/USDC position, the NVDA price
    ///      (stale every weekend, or paused by the issuer) would revert every liquidation of that position while
    ///      ETH keeps trading, and lenders would take the loss (audit 2026-10-15)
    function test_stockDebt_onlyInItsOwnPair() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__IlliquidDebtOutsideItsPair.selector, address(nvda))
        );
        collateral.borrow(ALICE, id, address(nvda), 1e18, ALICE);

        // In its own pair it adds nothing new: the collateral needs the NVDA price anyway
        vm.prank(CAROL);
        collateral.borrow(CAROL, stockId, address(nvda), 1e18, CAROL);
    }

    function _paused() internal view returns (bytes memory) {
        return abi.encodeWithSelector(ISenzuOracle.SenzuOracle__PricePaused.selector, address(nvda));
    }

    /// @dev A leveraged open borrows before its position exists, when the pair isn't known yet: the stock is checked
    ///      at the end of the lock instead. Borrowed against the NVDA/USDC position it opens, it goes through (the
    ///      Short and Balanced opens of a stock pair, refused at the borrow until 2026-10-22); against a WETH/USDC
    ///      one, it is still refused
    function test_stockDebt_borrowedBeforeTheOpen_checkedAtTheEnd() public {
        uint256 next = collateral.nextPositionId();
        bytes memory nvdaUsdc =
            abi.encode(address(nvda), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e15));
        bytes memory wethUsdc =
            abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e15));

        bytes[] memory outside = new bytes[](2);
        outside[0] = abi.encodeCall(collateral.borrow, (ALICE, next, address(nvda), 1e18, ALICE));
        outside[1] = abi.encodeCall(collateral.open, (ALICE, address(router), wethUsdc));
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__IlliquidDebtOutsideItsPair.selector, address(nvda))
        );
        router.run(outside);

        bytes[] memory own = new bytes[](3);
        own[0] = abi.encodeCall(collateral.borrow, (ALICE, next, address(nvda), 1e18, ALICE));
        own[1] = abi.encodeCall(collateral.borrow, (ALICE, next, address(usdc), 100e6, ALICE));
        own[2] = abi.encodeCall(collateral.open, (ALICE, address(router), nvdaUsdc));
        router.run(own);
        assertEq(borrowable.debtOf(ALICE, next, address(nvda)), 1e18);
        assertEq(borrowable.debtOf(ALICE, next, address(usdc)), 100e6);
    }

    /// @dev Paused: no borrowing (long or short), no collateral leaving a debt, no liquidation at a frozen price
    function test_pausedStock_nothingThatNeedsAPriceRuns() public {
        nvda.setOraclePaused(true);
        uint256 units = collateral.balanceOf(CAROL, stockId);

        vm.startPrank(CAROL);
        vm.expectRevert(_paused());
        collateral.borrow(CAROL, stockId, address(usdc), 100e6, CAROL);
        vm.expectRevert(_paused());
        collateral.redeem(CAROL, stockId, units / 10, CAROL, "");
        vm.stopPrank();

        // The short is frozen too: its debt can't be priced
        vm.prank(CAROL);
        vm.expectRevert(_paused());
        collateral.borrow(CAROL, stockId, address(nvda), 1e18, CAROL);

        // Even a position that would be liquidatable at the next price waits for that price
        nvdaFeed.set(20e8, block.timestamp);
        vm.prank(BOB);
        vm.expectRevert(_paused());
        lockLiquidator().liquidate(collateral, CAROL, stockId, address(usdc), type(uint256).max, BOB);
    }

    /// @dev Paused: repaying, adding collateral, collecting, leaving once debt-free, and lenders' withdrawals all work
    function test_pausedStock_everyWayOutStillWorks() public {
        nvda.setOraclePaused(true);

        // Carol adds margin, then repays everything and leaves
        adapter.setNextIncrease(1e14);
        vm.startPrank(CAROL);
        collateral.increaseLiquidity(CAROL, stockId, CAROL, "");
        usdc.mint(CAROL, 100e6);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(CAROL, stockId, address(usdc), type(uint256).max);
        nvda.mint(CAROL, 1e18);
        nvda.approve(address(borrowable), type(uint256).max);
        borrowable.repay(CAROL, stockId, address(nvda), type(uint256).max); // closes the short
        adapter.collectFees(CAROL, stockId, CAROL);
        uint256 units = collateral.balanceOf(CAROL, stockId);
        collateral.redeem(CAROL, stockId, units, CAROL, "");
        vm.stopPrank();
        assertEq(collateral.balanceOf(CAROL, stockId), 0);
        assertEq(borrowable.debtOf(CAROL, stockId, address(nvda)), 0);

        // Bob withdraws from both markets
        uint256 nvdaShares = borrowable.balanceOf(BOB, lenderId(address(nvda))) / 2;
        vm.prank(BOB);
        borrowable.withdraw(address(nvda), nvdaShares, BOB, BOB);
        uint256 usdcShares = borrowable.balanceOf(BOB, lenderId(address(usdc))) / 2;
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), usdcShares, BOB, BOB);
    }

    /// @dev Everything resumes when the token lifts the pause
    function test_pausedStock_resumesWhenLifted() public {
        nvda.setOraclePaused(true);
        vm.prank(CAROL);
        vm.expectRevert(_paused());
        collateral.borrow(CAROL, stockId, address(usdc), 100e6, CAROL);

        nvda.setOraclePaused(false);
        vm.prank(CAROL);
        collateral.borrow(CAROL, stockId, address(usdc), 100e6, CAROL);
        vm.prank(CAROL);
        collateral.borrow(CAROL, stockId, address(nvda), 1e18, CAROL);
    }
}
