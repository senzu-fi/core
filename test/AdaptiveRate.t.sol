// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../src/interfaces/ISenzuBorrowable.sol";
import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {lenderId} from "../src/libraries/Types.sol";
import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice The adaptive rate on a live borrowable: what moves the rate at target (time at a utilization) and what
///         doesn't (anything inside one block), and that the views report what the next accrual books
contract AdaptiveRateTest is HubFixture {
    uint256 constant YEAR = 365 days;
    uint256 constant INITIAL = MarketLogic.INITIAL_RATE_AT_TARGET;

    function setUp() public override {
        super.setUp();
        usdc.mint(CAROL, 100_000_000e6);
        vm.prank(CAROL);
        usdc.approve(address(borrowable), type(uint256).max);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp(); // via-IR can keep one block.timestamp read across warps
    }

    function _rateAtTarget() internal view returns (uint256 rateAtTarget) {
        (,,,,, rateAtTarget) = borrowable.marketState(address(usdc));
    }

    function _borrowApr() internal view returns (uint256) {
        (,,, uint256 borrowRate,,) = borrowable.marketState(address(usdc));
        return borrowRate * YEAR;
    }

    function _utilization() internal view returns (uint256 util) {
        (,, util,,,) = borrowable.marketState(address(usdc));
    }

    /// @dev Bob keeps `assets` of his USDC in the market and takes the rest out
    function _bobKeeps(uint256 assets) internal {
        uint256 shares = borrowable.balanceOf(BOB, lenderId(address(usdc)));
        uint256 keep = borrowable.convertToShares(address(usdc), assets);
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares - keep, BOB, BOB);
    }

    function _bobWithdrawsAll() internal {
        uint256 shares = borrowable.balanceOf(BOB, lenderId(address(usdc)));
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares, BOB, BOB);
    }

    /*  ============================================================
             Nothing within one block moves the rate at target
        ============================================================  */

    /// @dev A flash supply and withdraw, and a borrow and repay, in one block (one transaction or several): the rate
    ///      at target only adapts over elapsed time, from the utilization at the start of it, so the next period is
    ///      the one an untouched market has
    function test_attack_sameBlockFlashLeavesTheRateAlone() public {
        _bobKeeps(6_000e6);
        _borrow(ALICE, address(usdc), 3_000e6); // 50%
        vm.warp(_now() + 1 days);
        ethFeed.set(2000e8, _now());

        uint256 snapshot = vm.snapshotState();
        borrowable.accrueInterest(address(usdc));
        uint256 rateAtTarget = borrowable.getMarket(address(usdc)).rateAtTarget;
        uint256 borrowApr = _borrowApr();
        vm.warp(_now() + 1 days);
        borrowable.accrueInterest(address(usdc));
        uint256 nextRateAtTarget = borrowable.getMarket(address(usdc)).rateAtTarget;
        uint256 nextBorrows = borrowable.getMarket(address(usdc)).totalBorrowAssets;
        vm.revertToState(snapshot);

        // The flash: 10M USDC in (utilization ~0%), then out; Alice borrows to 100% and repays
        vm.startPrank(CAROL);
        uint256 shares = borrowable.supply(address(usdc), 10_000_000e6, CAROL);
        assertLt(_utilization(), 0.001e18);
        borrowable.withdraw(address(usdc), shares, CAROL, CAROL);
        vm.stopPrank();
        uint256 cash = borrowable.getMarket(address(usdc)).totalSupplyAssets
            - borrowable.getMarket(address(usdc)).totalBorrowAssets;
        _borrow(ALICE, address(usdc), cash - 1e6);
        assertGt(_utilization(), 0.99e18);
        usdc.mint(ALICE, 10_000e6);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), cash - 1e6);
        vm.stopPrank();

        assertEq(borrowable.getMarket(address(usdc)).rateAtTarget, rateAtTarget, "unmoved in the block");
        assertApproxEqRel(_borrowApr(), borrowApr, 1e12, "the borrow rate is back where it was");

        vm.warp(_now() + 1 days);
        borrowable.accrueInterest(address(usdc));
        // Withdraw and repay round a unit toward the market, so utilization can differ by a unit in 1e10
        assertApproxEqAbs(
            borrowable.getMarket(address(usdc)).rateAtTarget, nextRateAtTarget, 1, "the next period is the same"
        );
        assertApproxEqAbs(borrowable.getMarket(address(usdc)).totalBorrowAssets, nextBorrows, 2, "and its interest");
    }

    /// @dev A lender holding 80% of a market withdraws, leaving it at 100% utilization. The curve jumps at once (16%
    ///      on a 4% rate at target, as a kink would), but the rate at target only grows with time spent there: an
    ///      hour moves it 1.15%, a day 31%. When the lender comes back the rate falls back the same way
    function test_attack_dominantLenderWithdrawsToFullUtilization() public {
        _bobKeeps(8_000e6);
        vm.prank(CAROL);
        borrowable.supply(address(usdc), 2_000e6, CAROL);
        _borrow(ALICE, address(usdc), 2_000e6);
        assertApproxEqRel(_utilization(), 0.2e18, 1e12);
        assertApproxEqRel(_borrowApr(), uint256(0.1e18) / 3, 1e11, "20%: 3.33% on an 8% rate at target");

        _bobWithdrawsAll();
        assertApproxEqRel(_utilization(), 1e18, 1e12);
        assertEq(_rateAtTarget(), INITIAL, "the rate at target hasn't moved");
        assertApproxEqRel(_borrowApr(), 0.32e18, 1e11, "the curve: 4x the rate at target");

        vm.warp(_now() + 1 hours);
        assertApproxEqRel(_rateAtTarget() * YEAR, 0.08092e18, 1e14, "an hour at 100%: 8% -> 8.09%");
        vm.warp(_now() + 23 hours);
        ethFeed.set(2000e8, _now());
        assertApproxEqRel(_rateAtTarget() * YEAR, 0.10522e18, 1e14, "a day at 100%: 8% * e^(100/365) = 10.52%");
        assertApproxEqRel(_borrowApr(), 0.42088e18, 1e14, "borrowing at 42%");

        // Bob comes back: utilization back near 20%, the rate at target where the day left it, the curve back down
        vm.prank(BOB);
        borrowable.supply(address(usdc), 8_000e6, BOB);
        assertApproxEqRel(_utilization(), 0.2e18, 1e15);
        assertApproxEqRel(_rateAtTarget() * YEAR, 0.10522e18, 1e14);
        assertApproxEqRel(_borrowApr(), 0.04384e18, 1e15, "4.38%");

        // At 20% the rate at target halves every ln 2 / (100 * 7/9) years (3.25 days), down to the floor
        vm.warp(_now() + 281_036);
        assertApproxEqRel(_rateAtTarget() * YEAR, 0.05261e18, 1e15, "halved");
        vm.warp(_now() + 30 days);
        assertEq(_rateAtTarget(), MarketLogic.MIN_RATE_AT_TARGET, "and on to the 1% floor");
    }

    /// @dev A lender keeping a market at 100% for ten days takes the rate at target to its ceiling, and borrowers to
    ///      150% a year at most
    function test_attack_fullUtilizationCapsAt150Percent() public {
        _bobKeeps(2_000e6);
        _borrow(ALICE, address(usdc), 2_000e6);
        vm.warp(_now() + 10 days);
        assertEq(_rateAtTarget(), MarketLogic.MAX_RATE_AT_TARGET);
        assertApproxEqRel(_borrowApr(), 1.5e18, 1e11);
        assertLe(_borrowApr(), 1.5e18);
    }

    /*  ================================================
                            Accrual
        ================================================  */

    /// @dev A market without borrows still adapts: an idle market drifts down to the floor, so the first borrower
    ///      after a quiet month pays 1% at the target, not the 4% it started at
    function test_zeroBorrowsStillAdapt() public {
        assertEq(borrowable.getMarket(address(weth)).totalBorrowAssets, 0);
        vm.warp(_now() + 218_591); // ln 2 / 100 years
        borrowable.accrueInterest(address(weth));
        assertApproxEqRel(borrowable.getMarket(address(weth)).rateAtTarget, INITIAL / 2, 1e12, "halved");
        vm.warp(_now() + 30 days);
        borrowable.accrueInterest(address(weth));
        assertEq(borrowable.getMarket(address(weth)).rateAtTarget, MarketLogic.MIN_RATE_AT_TARGET);
    }

    /// @dev An empty market says nothing about demand: created, left empty for a month, it starts at 4% at its
    ///      first supply, as a Morpho market starts at its first interaction
    function test_emptyMarketDoesNotAdapt() public {
        MockERC20 dai = new MockERC20("DAI", 18);
        oracle.addFeed(address(dai), address(new MockAggregator(8, 1e8)), 1 days);
        borrowable.createMarket(address(dai), 0.1e18);
        vm.warp(_now() + 30 days);
        (,,,,, uint256 rateAtTarget) = borrowable.marketState(address(dai));
        assertEq(rateAtTarget, INITIAL, "the view");

        dai.mint(CAROL, 1_000e18);
        vm.startPrank(CAROL);
        dai.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(dai), 1_000e18, CAROL);
        vm.stopPrank();
        assertEq(borrowable.getMarket(address(dai)).rateAtTarget, INITIAL, "at its first supply");
        assertEq(borrowable.getMarket(address(dai)).lastAccrual, _now());

        vm.warp(_now() + 218_591);
        borrowable.accrueInterest(address(dai));
        assertApproxEqRel(borrowable.getMarket(address(dai)).rateAtTarget, INITIAL / 2, 1e12, "supplied: it drifts");
    }

    /// @dev Ten years without a touch at 95%: accrues without reverting. The rate at target reaches the ceiling in
    ///      11 days (from 8%) and stays, so the period integrates to 2.5 · (37.5% · 10 years, less the ramp) = 9.36 and
    ///      the debt compounds e^9.36 = 11,623 times
    function test_untouchedForYearsAccrues() public {
        _bobKeeps(2_000e6);
        _borrow(ALICE, address(usdc), 1_900e6);
        uint256 borrows = borrowable.getMarket(address(usdc)).totalBorrowAssets;
        vm.warp(_now() + 10 * YEAR);
        borrowable.accrueInterest(address(usdc));
        borrowable.accrueInterest(address(weth));
        uint256 debt = borrowable.getMarket(address(usdc)).totalBorrowAssets;
        assertApproxEqRel(debt, borrows * 11_623, 1e15, "ten years compounding to e^9.36");
        assertEq(borrowable.getMarket(address(weth)).rateAtTarget, MarketLogic.MIN_RATE_AT_TARGET);
    }

    /// @dev The headline on the live borrowable: a period accrued in up to 50 uneven pieces (anyone calling
    ///      accrueInterest) books what one accrual books. At 100% utilization, which interest keeps at 100%
    function testFuzz_splitAccrualsBookTheSame(uint256 elapsed, uint256 seed) public {
        _bobKeeps(2_000e6);
        _borrow(ALICE, address(usdc), 2_000e6);
        assertEq(_utilization(), 1e18);
        uint256 steps = bound(seed, 2, 50);
        elapsed = bound(elapsed, steps, 60 days);
        uint256 start = _now();

        uint256 snapshot = vm.snapshotState();
        uint256 at;
        for (uint256 i; i < steps; ++i) {
            at = i == steps - 1
                ? elapsed
                : bound(uint256(keccak256(abi.encode(seed, i))), at + 1, elapsed - (steps - 1 - i));
            vm.warp(start + at);
            borrowable.accrueInterest(address(usdc));
        }
        uint256 splitBorrows = borrowable.getMarket(address(usdc)).totalBorrowAssets;
        uint256 splitRateAtTarget = borrowable.getMarket(address(usdc)).rateAtTarget;
        vm.revertToState(snapshot);

        vm.warp(start + elapsed);
        borrowable.accrueInterest(address(usdc));
        // The stored rate at target's unit per accrual (as Morpho), on the interest; and a unit of USDC per accrual
        assertApproxEqRel(
            borrowable.getMarket(address(usdc)).rateAtTarget, splitRateAtTarget, steps * 3.2e9, "rate at target"
        );
        uint256 interest = borrowable.getMarket(address(usdc)).totalBorrowAssets - 2_000e6;
        assertApproxEqAbs(
            borrowable.getMarket(address(usdc)).totalBorrowAssets,
            splitBorrows,
            steps + interest * steps * 3.2e9 / 1e18,
            "the interest"
        );
    }

    /*  ================================================
                             Views
        ================================================  */

    /// @dev Everything the views report after a wait is what an accrual at that moment books
    /// @dev The indexer charts the rate's trend from the event, with no call per market
    function test_accrueInterestCarriesTheRateAtTarget() public {
        _bobKeeps(2_000e6);
        _borrow(ALICE, address(usdc), 2_000e6);
        vm.warp(_now() + 1 days);
        uint256 rateAtTarget = _rateAtTarget();
        assertGt(rateAtTarget, INITIAL, "100% utilization: adapting up");
        uint256 borrowAssets = borrowable.getMarket(address(usdc)).totalBorrowAssets;

        vm.recordLogs();
        borrowable.accrueInterest(address(usdc));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != ISenzuBorrowable.AccrueInterest.selector) continue;
            (uint256 interest,, uint256 totalBorrowAssets, uint256 emitted) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
            assertGt(interest, 0);
            assertEq(totalBorrowAssets, borrowAssets + interest);
            assertEq(emitted, rateAtTarget);
            assertEq(emitted, borrowable.getMarket(address(usdc)).rateAtTarget);
            found = true;
        }
        assertTrue(found);
    }

    function test_viewsEqualTheNextAccrual() public {
        _bobKeeps(10_000e6);
        _borrow(ALICE, address(usdc), 6_000e6);
        vm.warp(_now() + 5 days);

        (
            uint256 supplyAssets,
            uint256 borrowAssets,
            uint256 util,
            uint256 borrowRate,
            uint256 supplyRate,
            uint256 rateAtTarget
        ) = borrowable.marketState(address(usdc));
        uint256 debt = borrowable.debtOf(ALICE, id, address(usdc));
        uint256 bobAssets =
            borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, lenderId(address(usdc))));
        assertLt(rateAtTarget, INITIAL, "60% utilization: adapting down");

        borrowable.accrueInterest(address(usdc));
        assertEq(borrowable.getMarket(address(usdc)).rateAtTarget, rateAtTarget, "rate at target");
        assertEq(borrowable.getMarket(address(usdc)).totalBorrowAssets, borrowAssets, "borrows");
        assertEq(borrowable.getMarket(address(usdc)).totalSupplyAssets, supplyAssets, "supply");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), debt, "debt");
        assertEq(
            borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, lenderId(address(usdc)))),
            bobAssets,
            "lender assets"
        );
        (,, uint256 utilAfter, uint256 borrowRateAfter, uint256 supplyRateAfter,) =
            borrowable.marketState(address(usdc));
        assertEq(utilAfter, util);
        assertEq(borrowRateAfter, borrowRate, "the borrow rate the next period starts from");
        assertEq(supplyRateAfter, supplyRate);
        assertEq(borrowRate, MarketLogic.curve(rateAtTarget, MarketLogic.utilizationError(util)));
    }
}
