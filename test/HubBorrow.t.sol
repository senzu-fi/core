// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HealthMath} from "../src/libraries/HealthMath.sol";
import {HealthResult, lenderId} from "../src/libraries/Types.sol";
import {MockAdapter, MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {badDebtIn} from "./utils/Logs.sol";
import {ISenzuBorrowable} from "src/interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";
import {ISenzuRiskConfig} from "src/interfaces/ISenzuRiskConfig.sol";
import {SenzuPreviews} from "src/periphery/SenzuPreviews.sol";

contract HubBorrowTest is HubFixture {
    /*  ================================================
                              open
        ================================================  */

    function test_open_mintsLiquidity() public view {
        assertEq(collateral.balanceOf(ALICE, id), L);
        assertEq(collateral.nextPositionId(), 2);
        assertEq(keccak256(abi.encode(address(adapter), adapter.shape(id).token0, adapter.shape(id).token1)), pairKey);
        assertApproxEqRel(_collateralUsd(), 8944e18, 0.01e18);
        _assertSupplyMatchesAdapter(id);
    }

    /// @dev Positions open only through the set's adapter: `open` and `reserve` take none, so no other adapter
    ///      (not even one built for this very collateral) can ever be named
    function test_open_alwaysThroughTheSetsAdapter() public {
        new MockAdapter(address(collateral)); // exists, but nothing can route a position to it
        uint256 other = _open(BOB, L);
        assertEq(collateral.adapter(), address(adapter));
        assertEq(
            keccak256(abi.encode(address(adapter), adapter.shape(other).token0, adapter.shape(other).token1)),
            pairKey,
            "held by the set's adapter"
        );
    }

    function test_open_tokensMustBeCollateral() public {
        MockERC20 meme = new MockERC20("MEME", 18);
        bytes memory data = abi.encode(address(meme), address(usdc), uint160(1), uint160(2), uint128(1));
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__CollateralNotEnabled.selector, address(meme))
        );
        collateral.open(ALICE, address(this), data);
    }

    function test_open_pairMustBeEnabled() public {
        riskConfig.setPairEnabled(address(adapter), address(weth), address(usdc), false);
        bytes memory data = abi.encode(address(weth), address(usdc), uint160(1), uint160(2), uint128(1));
        vm.expectRevert(abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__PairNotEnabled.selector, pairKey));
        collateral.open(ALICE, address(this), data);
    }

    /*  ================================================
                             borrow
        ================================================  */

    function test_borrow_withinLimit() public {
        uint256 amount = _usdcFor(0.5e18);
        _borrow(ALICE, address(usdc), amount);

        assertEq(usdc.balanceOf(ALICE), amount);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), amount);
        assertTrue(borrowable.hasDebt(ALICE, id));
        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.healthWad, 1e18);
        assertApproxEqRel(h.debtUsdWad, amount * 1e12, 1e12);
    }

    /// @dev No buffer: the borrow check is the liquidation check. The lens's max borrow (a search that stops within
    ///      1e-6 of the limit, on the safe side) passes and leaves the position not liquidatable at the same prices;
    ///      anything past that tolerance is refused
    function test_borrow_upToTheLiquidationLine() public {
        SenzuPreviews lens = new SenzuPreviews(address(collateral));
        uint256 max = lens.maxBorrow(ALICE, id, address(usdc));
        assertGt(max, _usdcFor(0.85e18), "the limit is the liquidation line (~87%)");

        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.borrow(ALICE, id, address(usdc), max + max / 1e6 + 1, ALICE);

        _borrow(ALICE, address(usdc), max);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0, "a borrow that passes is never liquidatable");
        assertGe(collateral.health(ALICE, id).minSurplusUsdWad, 0);
    }

    /// @dev The lens books a borrow exactly as the borrowable does (shares rounded up, merged with the position's
    ///      existing debt in that asset), so its maximum always passes, also on dust positions where its search is
    ///      exact to the unit, and again after interest accrues. A randomized invariant run caught it adding the new
    ///      debt as a separate line instead (1-2 units short) once the borrow buffer was gone
    function testFuzz_borrow_lensMaximumAlwaysPasses(uint128 liquidity, bool weth_, bool withFee, uint32 wait) public {
        liquidity = uint128(bound(liquidity, 1e6, 1e11)); // dust: the lens's search is exact to the unit
        if (withFee) riskConfig.setBorrowFee(address(adapter), 0.001e18);
        address asset = weth_ ? address(weth) : address(usdc);
        // A market where a debt share is worth more than one unit: others borrowed, and interest accrued
        _borrow(ALICE, asset, weth_ ? 1e18 : 2_000e6);
        vm.warp(block.timestamp + 12 hours);
        uint256 dust = _open(CAROL, liquidity);
        SenzuPreviews lens = new SenzuPreviews(address(collateral));

        for (uint256 round; round < 2; ++round) {
            uint256 max = lens.maxBorrow(CAROL, dust, asset);
            if (max == 0) return;
            vm.prank(CAROL);
            collateral.borrow(CAROL, dust, asset, max, CAROL);
            assertFalse(
                collateral.health(CAROL, dust).minSurplusUsdWad < 0, "a borrow that passes is never liquidatable"
            );
            vm.warp(block.timestamp + bound(wait, 0, 12 hours)); // interest accrues (feeds stay fresh: 1-day heartbeat)
        }
    }

    function test_borrow_tiedDebtAllowsMoreThanUnrelatedWouldNot() public {
        // Borrowing WETH (token0 of the collateral) moves with the collateral, so 80% is fine
        uint256 wethAmount = _collateralUsd() * 0.8e18 / 1e18 / 2000;
        _borrow(ALICE, address(weth), wethAmount);
        assertGt(collateral.health(ALICE, id).healthWad, 1e18);
    }

    function test_borrow_onlyAccountOrOperator() public {
        vm.prank(BOB);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Unauthorized.selector);
        collateral.borrow(ALICE, id, address(usdc), 100e6, BOB);
    }

    /// @dev The borrowable's debt book moves only through its collateral: `collectRepayment` would otherwise pull
    ///      from any wallet that approved the borrowable (Bob's, here)
    function test_borrowable_debtOnlyThroughTheCollateral() public {
        _borrow(ALICE, address(usdc), 1_000e6);
        vm.startPrank(ALICE);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NotCollateral.selector);
        borrowable.borrow(ALICE, id, address(usdc), 1e6, ALICE);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NotCollateral.selector);
        borrowable.repayFor(ALICE, id, address(usdc), 1_000e6, 0);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NotCollateral.selector);
        borrowable.collectRepayment(BOB, address(usdc), 1e6);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NotCollateral.selector);
        borrowable.writeOff(ALICE, id);
        vm.stopPrank();
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 1_000e6);
    }

    /// @dev Borrows and withdrawals take up to the cash and not one unit more
    function test_cash_boundsBorrowAndWithdraw() public {
        vm.startPrank(BOB);
        borrowable.withdraw(address(usdc), borrowable.convertToShares(address(usdc), 995_000e6), BOB, BOB);
        vm.stopPrank();
        _borrow(ALICE, address(usdc), 4_000e6);
        (uint256 supplied, uint256 borrowed,,,,) = borrowable.marketState(address(usdc));
        uint256 cash = supplied - borrowed;
        assertGt(cash, 0);

        bytes memory noCash =
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__InsufficientCash.selector, address(usdc));
        vm.prank(ALICE);
        vm.expectRevert(noCash);
        collateral.borrow(ALICE, id, address(usdc), cash + 1, ALICE);

        uint256 bobShares = borrowable.balanceOf(BOB, lenderId(address(usdc)));
        vm.prank(BOB);
        vm.expectRevert(noCash);
        borrowable.withdraw(address(usdc), bobShares, BOB, BOB);

        uint256 maxShares = borrowable.convertToShares(address(usdc), cash);
        vm.prank(BOB);
        uint256 withdrawn = borrowable.withdraw(address(usdc), maxShares, BOB, BOB);
        assertApproxEqAbs(withdrawn, cash, 1, "the whole cash, less rounding");
        assertEq(borrowable.maxWithdraw(address(usdc), BOB), cash - withdrawn);
    }

    function test_openAndRedeem_zeroUnitsRevert() public {
        bytes memory empty =
            abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(0));
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__ZeroAmount.selector);
        collateral.open(ALICE, ALICE, empty);

        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__ZeroAmount.selector);
        collateral.redeem(ALICE, id, 0, ALICE, "");
    }

    /// @dev One named error for redeeming more than the balance, with or without debt
    function test_redeem_moreThanTheBalanceReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientUnits.selector);
        collateral.redeem(ALICE, id, L + 1, ALICE, "");

        _borrow(ALICE, address(usdc), 1_000e6);
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientUnits.selector);
        collateral.redeem(ALICE, id, L + 1, ALICE, "");
    }

    function test_repay_withoutDebtReverts() public {
        vm.prank(BOB);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__NoDebt.selector);
        borrowable.repay(ALICE, id, address(usdc), 1e6);
    }

    /// @dev Two debts in any markets, a third doesn't fit
    function test_borrow_atMostTwoDebts() public {
        MockERC20 other = new MockERC20("TKN", 6);
        oracle.addFeed(address(other), address(new MockAggregator(8, 1e8)), 1 days);
        borrowable.createMarket(address(other), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(other), 1.05e18, 1.05e18, false);
        riskConfig.setLiquid(address(adapter), address(other));
        other.mint(BOB, 1_000e6);
        vm.startPrank(BOB);
        other.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(other), 1_000e6, BOB);
        vm.stopPrank();

        _borrow(ALICE, address(usdc), 1_000e6);
        _borrow(ALICE, address(weth), 0.1e18);
        vm.prank(ALICE);
        vm.expectRevert(ISenzuBorrowable.SenzuBorrowable__TooManyDebts.selector);
        collateral.borrow(ALICE, id, address(other), 10e6, ALICE);
    }

    function test_borrow_multipleMarkets() public {
        _borrow(ALICE, address(usdc), 2_000e6);
        _borrow(ALICE, address(weth), 1e18);
        (address asset0,, address asset1,) = borrowable.debts(ALICE, id);
        assertEq(asset0, address(usdc));
        assertEq(asset1, address(weth));
        assertApproxEqRel(collateral.health(ALICE, id).debtUsdWad, 4_000e18, 1e12);
    }

    function test_interestAccrues() public {
        _borrow(ALICE, address(usdc), 4_000e6);
        vm.warp(block.timestamp + 365 days);
        ethFeed.set(2000e8, block.timestamp);
        MockAggregator(_usdcFeed()).set(1e8, block.timestamp);
        assertGt(borrowable.debtOf(ALICE, id, address(usdc)), 4_000e6);
    }

    function _usdcFeed() internal view returns (address feed) {
        (feed,,) = oracle.feedOf(address(usdc));
    }

    /*  ================================================
                             repay
        ================================================  */

    function test_repay_partialThenFullByAnyone() public {
        _borrow(ALICE, address(usdc), 4_000e6);

        vm.prank(BOB);
        borrowable.repay(ALICE, id, address(usdc), 1_000e6);
        assertApproxEqAbs(borrowable.debtOf(ALICE, id, address(usdc)), 3_000e6, 1);

        vm.prank(BOB);
        uint256 repaid = borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        assertApproxEqAbs(repaid, 3_000e6, 1);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
        assertFalse(borrowable.hasDebt(ALICE, id));
        assertEq(borrowable.getMarket(address(usdc)).totalBorrowShares, 0);
    }

    /*  ================================================
                    units and the burn hook
        ================================================  */

    /// @dev Units don't transfer, with or without debt; an operator still acts for the owner
    function test_unitsDontTransfer() public {
        vm.startPrank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NonTransferable.selector);
        collateral.transfer(BOB, id, 1);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NonTransferable.selector);
        collateral.transferFrom(ALICE, BOB, id, 1);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NonTransferable.selector);
        collateral.approve(BOB, id, type(uint256).max);
        collateral.setOperator(BOB, true);
        vm.stopPrank();
        assertEq(collateral.balanceOf(ALICE, id), L);

        vm.prank(BOB);
        collateral.redeem(ALICE, id, L / 10, BOB, "");
        assertEq(collateral.balanceOf(ALICE, id), L - L / 10);
    }

    function test_hook_redeemChecksHealth() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.redeem(ALICE, id, L / 2, ALICE, "");

        vm.prank(ALICE);
        collateral.redeem(ALICE, id, L / 20, ALICE, "");
        _assertSupplyMatchesAdapter(id);
    }

    /*  ================================================
                         reserve factor
        ================================================  */

    /// @dev Interest earned before a reserve factor change is split at the old factor: the setter accrues first
    function test_setReserveFactor_accruesFirst() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        vm.warp(block.timestamp + 365 days);
        uint256 lender = lenderId(address(usdc));

        // What the DAO gets for the year at the old 10%...
        uint256 snapshot = vm.snapshotState();
        borrowable.accrueInterest(address(usdc));
        uint256 atOldFactor =
            borrowable.balanceOf(DAO, lender) + borrowable.getMarket(address(usdc)).pendingReserveShares;
        assertGt(atOldFactor, 0);
        vm.revertToState(snapshot);

        // ...is what it gets when the factor drops to 0 at the end of that year
        borrowable.setReserveFactor(address(usdc), 0);
        assertEq(
            borrowable.balanceOf(DAO, lender) + borrowable.getMarket(address(usdc)).pendingReserveShares, atOldFactor
        );

        // From then on, nothing more
        vm.warp(block.timestamp + 365 days);
        borrowable.accrueInterest(address(usdc));
        assertEq(
            borrowable.balanceOf(DAO, lender) + borrowable.getMarket(address(usdc)).pendingReserveShares, atOldFactor
        );
    }

    /*  ================================================
             The pool price never gates a position
        ================================================  */

    /// @dev Valuation is oracle-only, so wherever the pool is pushed, health doesn't move and an indebted position
    ///      can still redeem (the borrow check still applies). Removing liquidity at a pushed price pays the
    ///      remover more than the oracle value of what they removed (the LP holdings are worth least at the true
    ///      price), and that extra comes from whoever pushed the pool, never from lenders.
    function testFuzz_poolPrice_neverMovesHealthOrBlocksRedeem(uint256 pushBps) public {
        pushBps = bound(pushBps, 1, 30_000); // the pool anywhere from ≈0 to 4x the oracle (√ price × 0.0001..4)
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        HealthResult memory before = collateral.health(ALICE, id);

        uint160 oracleSqrt = HealthMath.sqrtPriceX96FromUsd(2000e18, 1e18, 18, 6);
        uint256 pushed = oracleSqrt * pushBps / 10_000;
        adapter.setPoolSqrtPrice(uint160(pushed == 0 ? 1 : pushed));

        HealthResult memory moved = collateral.health(ALICE, id);
        assertEq(moved.minSurplusUsdWad, before.minSurplusUsdWad, "health ignores the pool price");
        assertEq(moved.collateralUsdWad, before.collateralUsdWad);

        vm.prank(ALICE);
        collateral.redeem(ALICE, id, L / 20, ALICE, "");
        // The borrow check still decides how much can come out
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.redeem(ALICE, id, L / 2, ALICE, "");
    }

    /*  ================================================
                              fees
        ================================================  */

    function test_fees_collectedByHolder() public {
        uint256 lpId = id;
        adapter.accrueFees(lpId, 1e18, 100e6);

        (uint256 fee0, uint256 fee1) = adapter.feesOwed(ALICE, id);
        assertApproxEqAbs(fee0, 1e18, 1e6);
        assertApproxEqAbs(fee1, 100e6, 1);

        vm.prank(ALICE);
        adapter.collectFees(ALICE, id, ALICE);
        assertEq(weth.balanceOf(ALICE), fee0);
        (fee0, fee1) = adapter.feesOwed(ALICE, id);
        assertEq(fee0, 0);
        assertEq(fee1, 0);
    }

    /// @dev A seize is the one way units change hands: the seized units take what they earned and Alice hadn't
    ///      collected, and each holder earns from then on at its own balance
    function test_fees_splitByUnitsAcrossASeize() public {
        uint256 lpId = id;
        adapter.accrueFees(lpId, 1e18, 0);

        // Carol liquidates part of Alice's debt and receives units
        _liquidatePart(CAROL);
        uint256 alice = collateral.balanceOf(ALICE, id);
        uint256 carol = collateral.balanceOf(CAROL, id);
        assertGt(carol, 0);
        assertEq(alice + carol, L);

        adapter.accrueFees(lpId, 1e18, 0);
        (uint256 aliceFees,) = adapter.feesOwed(ALICE, id);
        (uint256 carolFees,) = adapter.feesOwed(CAROL, id);
        // Neither was collected: each holder gets its units' share of both
        assertApproxEqAbs(aliceFees, 2e18 * alice / L, 1e6);
        assertApproxEqAbs(carolFees, 2e18 * carol / L, 1e6);
    }

    /*  ================================================
                              lock
        ================================================  */

    function _leverageCalls(uint256 borrowAmount, bool addLiquidity) internal view returns (bytes[] memory calls) {
        calls = new bytes[](addLiquidity ? 2 : 1);
        calls[0] = abi.encodeCall(collateral.borrow, (ALICE, id, address(usdc), borrowAmount, address(router)));
        if (addLiquidity) calls[1] = abi.encodeCall(collateral.increaseLiquidity, (ALICE, id, address(router), ""));
    }

    function test_lock_leverageCheckedOnceAtTheEnd() public {
        // 120% of the collateral would fail on its own, but the same lock doubles the collateral
        uint256 amount = _usdcFor(1.2e18);
        adapter.setNextIncrease(L * 2);

        router.run(_leverageCalls(amount, true));

        assertEq(collateral.balanceOf(ALICE, id), L * 3);
        assertGt(collateral.health(ALICE, id).healthWad, 1e18);
        _assertSupplyMatchesAdapter(id);
    }

    function test_lock_unhealthyAtTheEndReverts() public {
        uint256 amount = _usdcFor(1.2e18);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        router.run(_leverageCalls(amount, false));
    }

    /// @dev The audit's lock drain (2026-10-05): borrow a market's whole cash inside a lock, then write the debt off in
    ///      the same lock. Bad debt is only
    ///      resolved outside a lock, after every deferred check has run
    function test_lock_resolveBadDebtRefusedInsideALock() public {
        uint256 cash = usdc.balanceOf(address(borrowable));
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(collateral.borrow, (address(router), id, address(usdc), cash, address(router)));
        calls[1] = abi.encodeCall(collateral.resolveBadDebt, (address(router), id));

        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Locked.selector);
        router.run(calls);
        assertEq(usdc.balanceOf(address(borrowable)), cash);
    }

    /// @dev Audit 2026-10-05: one unit worth nothing at oracle prices used to block both the liquidation (nothing to
    ///      seize) and the write-off (collateral remaining), leaving the bad debt on lender books forever. A unit
    ///      worth exactly zero now goes to the DAO reserves with the write-off
    function test_resolveBadDebt_zeroValueUnitsDontBlockIt() public {
        address dave = address(0xDA7E);
        bytes memory data = abi.encode(
            address(weth),
            address(usdc),
            HealthMath.sqrtPriceX96FromUsd(1500e18, 1e18, 18, 6),
            HealthMath.sqrtPriceX96FromUsd(2500e18, 1e18, 18, 6),
            uint128(1e15)
        );
        vm.prank(dave);
        (uint256 did,,,,,) = collateral.open(dave, dave, data);
        uint256 borrowWeth = collateral.health(dave, did).collateralUsdWad * 7 / 10 / 2000;
        vm.prank(dave);
        collateral.borrow(dave, did, address(weth), borrowWeth, dave);

        // ETH runs above the range: the position is all USDC and worth less than the WETH debt
        ethFeed.set(3500e8, block.timestamp);
        weth.mint(CAROL, 100e18);
        vm.startPrank(CAROL);
        weth.approve(address(borrowable), type(uint256).max);
        vm.stopPrank();
        // The liquidation that leaves the borrower the fewest units (units don't transfer, so a liquidator leaving dust
        // is how zero-value units stay behind): the largest repay that still leaves some, found by bisection
        uint256 debtLeft = borrowable.debtOf(dave, did, address(weth));
        (uint256 lo, uint256 hi) = (0, debtLeft);
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(CAROL);
            lockLiquidator().liquidate(collateral, dave, did, address(weth), mid, CAROL);
            bool left = collateral.balanceOf(dave, did) > 0;
            vm.revertToState(snap);
            (lo, hi) = left ? (mid, hi) : (lo, mid);
        }
        vm.prank(CAROL);
        lockLiquidator().liquidate(collateral, dave, did, address(weth), lo, CAROL);
        assertGt(collateral.balanceOf(dave, did), 0);
        assertEq(collateral.health(dave, did).collateralUsdWad, 0);
        assertGt(borrowable.debtOf(dave, did, address(weth)), 0);

        uint256 daoBefore = collateral.balanceOf(DAO, did);
        uint256 dust = collateral.balanceOf(dave, did);
        vm.recordLogs();
        collateral.resolveBadDebt(dave, did);
        assertFalse(borrowable.hasDebt(dave, did));
        assertEq(collateral.balanceOf(dave, did), 0);
        assertEq(collateral.balanceOf(DAO, did), daoBefore + dust);
        assertGt(badDebtIn(vm.getRecordedLogs(), address(borrowable), address(weth)), 0);
    }

    /// @dev Audit 2026-10-06: inside a lock a BORROW leaves the position short until the INCREASE it pays for, and code
    ///      running in that lock (a callback, an allowance spender's own lock) could liquidate it right then and take
    ///      the incentive. A position waiting for its end-of-lock check can't be liquidated, flash or not
    function test_lock_positionWithADeferredCheckCantBeLiquidated() public {
        usdc.mint(address(router), 1_000_000e6);
        vm.prank(address(router));
        usdc.approve(address(borrowable), type(uint256).max);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(collateral.borrow, (ALICE, id, address(usdc), _usdcFor(1.2e18), ALICE));
        calls[1] = abi.encodeCall(collateral.liquidate, (ALICE, id, address(usdc), type(uint256).max, address(router)));
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__CheckPending.selector, ALICE, id));
        router.run(calls);

        calls[1] = abi.encodeCall(collateral.liquidate, (ALICE, id, address(usdc), type(uint256).max, address(router)));
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__CheckPending.selector, ALICE, id));
        router.run(calls);
    }

    function test_lock_notReentrant() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature("lock(bytes)", abi.encode(new bytes[](0)));
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Locked.selector);
        router.run(calls);
    }

    /*  ================================================
                       unsupported tokens
        ================================================  */

    function test_feeOnTransfer_repayReverts() public {
        _borrow(ALICE, address(usdc), 1_000e6);

        usdc.setTransferFee(10); // 0.1%
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuBorrowable.SenzuBorrowable__UnsupportedToken.selector, address(usdc))
        );
        borrowable.repay(ALICE, id, address(usdc), 500e6);
    }
}
