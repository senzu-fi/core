// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {RewardLedger} from "../../src/adapters/RewardLedger.sol";
import {SenzuCollateral} from "../../src/core/SenzuCollateral.sol";
import {ISenzuAdapter} from "../../src/interfaces/ISenzuAdapter.sol";
import {ISenzuRewardsAdapter} from "../../src/interfaces/ISenzuRewardsAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

/**
 *  @title  AdapterSuite
 *  @notice Shared conformance test suite every adapter's test contract inherits and must pass.
 */
abstract contract AdapterSuite is Test {
    /*  ================================================
                            Hooks
        ================================================  */

    function _suiteCollateral() internal view virtual returns (SenzuCollateral);

    function _suiteAdapter() internal view virtual returns (ISenzuAdapter);

    function _suiteAlice() internal view virtual returns (address);

    function _suiteLiquidator() internal view virtual returns (address);

    function _suiteDepositTokens()
        internal
        view
        virtual
        returns (address token0, address token1, uint256 amount0, uint256 amount1);

    function _suiteMintData() internal view virtual returns (bytes memory);

    function _suiteHasSeparateFees() internal pure virtual returns (bool) {
        return true;
    }

    /// @dev WETH address when the adapter's test pool uses native ETH; `address(0)` for ERC-20-only DEXes
    function _suiteNativeEthWeth() internal view virtual returns (address) {
        return address(0);
    }

    function _suiteDustUnits(uint256) internal view virtual returns (uint256) {
        return 1;
    }

    function _suiteGenerateFees() internal virtual;

    /// @dev Partially liquidates `_suiteAlice()` on `id`, moving units to `_suiteLiquidator()` while leaving both
    ///      holding positive balances, and restores any mocked oracle prices
    function _suiteLiquidatePart(uint256 id) internal virtual returns (uint256 seized);

    /// @dev Fully liquidates `_suiteAlice()` on `id` (100% of her units moved to `_suiteLiquidator()`), and restores
    ///      any mocked oracle prices
    function _suiteLiquidateFull(uint256 id) internal virtual returns (uint256 seized);

    function _suiteCheckBooks() internal view virtual {}

    /*  ================================================
                           Helpers
        ================================================  */

    function _suiteOpen(bytes memory mintData, address refundTo, uint256 mul0, uint256 mul1)
        internal
        returns (uint256 id, uint256 units, uint256 used0, uint256 used1)
    {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        (address t0, address t1, uint256 a0, uint256 a1) = _suiteDepositTokens();
        uint256 send0 = a0 * mul0;
        uint256 send1 = a1 * mul1;
        deal(t0, alice, IERC20(t0).balanceOf(alice) + send0);
        deal(t1, alice, IERC20(t1).balanceOf(alice) + send1);
        vm.startPrank(alice);
        IERC20(t0).transfer(address(ad), send0);
        IERC20(t1).transfer(address(ad), send1);
        (id, units,,, used0, used1) = col.open(alice, refundTo, mintData);
        vm.stopPrank();
    }

    function _suiteAssertApprox(uint256 actual, uint256 expected, string memory label) internal pure {
        if (expected > 1_000) {
            assertApproxEqRel(actual, expected, 0.002e18, label);
        } else {
            assertApproxEqAbs(actual, expected, 5, label);
        }
    }

    /*  ================================================
                            Tests
        ================================================  */

    function test_suite_openIncreasePartialAndFullDecrease() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        (address t0, address t1, uint256 a0, uint256 a1) = _suiteDepositTokens();

        (uint256 id, uint256 opened, uint256 used0, uint256 used1) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        assertGt(opened, 0, "opened units");
        assertGt(used0 + used1, 0, "used tokens");
        assertEq(col.balanceOf(alice, id), opened);
        assertEq(col.totalSupply(id), ad.units(id));

        // Increase
        deal(t0, alice, IERC20(t0).balanceOf(alice) + a0);
        deal(t1, alice, IERC20(t1).balanceOf(alice) + a1);
        vm.startPrank(alice);
        IERC20(t0).transfer(address(ad), a0);
        IERC20(t1).transfer(address(ad), a1);
        (uint256 added,,) = col.increaseLiquidity(alice, id, alice, "");
        vm.stopPrank();
        assertGt(added, 0, "added units");
        assertEq(col.balanceOf(alice, id), opened + added);
        assertEq(col.totalSupply(id), ad.units(id));

        // Partial decrease
        address recipient = makeAddr("partialRecipient");
        uint256 half = (opened + added) / 2;
        vm.prank(alice);
        (uint256 p0, uint256 p1) = col.redeem(alice, id, half, recipient, "");
        assertGt(p0 + p1, 0, "partial redeem paid principal");
        assertEq(IERC20(t0).balanceOf(recipient), p0);
        assertEq(IERC20(t1).balanceOf(recipient), p1);
        assertEq(col.balanceOf(alice, id), opened + added - half);
        assertEq(col.totalSupply(id), ad.units(id));

        // Full decrease
        uint256 rest = col.balanceOf(alice, id);
        vm.prank(alice);
        (uint256 f0, uint256 f1) = col.redeem(alice, id, rest, recipient, "");
        assertGt(f0 + f1, 0, "full redeem paid principal");
        assertEq(IERC20(t0).balanceOf(recipient), p0 + f0);
        assertEq(IERC20(t1).balanceOf(recipient), p1 + f1);
        assertEq(col.balanceOf(alice, id), 0);
        assertEq(col.totalSupply(id), 0);
        assertEq(ad.units(id), 0);
        _suiteCheckBooks();
    }

    function test_suite_dustRedeem() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        uint256 dust = _suiteDustUnits(opened);
        assertGt(dust, 0);
        assertLt(dust, opened);

        vm.prank(alice);
        col.redeem(alice, id, dust, alice, "");
        assertEq(col.balanceOf(alice, id), opened - dust, "dust burned");
        assertEq(col.totalSupply(id), ad.units(id), "supply matches adapter");
        _suiteCheckBooks();
    }

    function test_suite_feesPaidOnlyOnFullRedeem() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        (address t0, address t1,,) = _suiteDepositTokens();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();

        if (!_suiteHasSeparateFees()) {
            (uint256 o0, uint256 o1) = ad.feesOwed(alice, id);
            assertEq(o0 + o1, 0, "no separate fees");
            vm.prank(alice);
            (uint256 c0, uint256 c1) = ad.collectFees(alice, id, alice);
            assertEq(c0 + c1, 0);
            _suiteCheckBooks();
            return;
        }

        // Send principal to a distinct recipient so any tokens arriving at `alice` are fees
        address recipient = makeAddr("feeTestRecipient");
        uint256 alice0Before = IERC20(t0).balanceOf(alice);
        uint256 alice1Before = IERC20(t1).balanceOf(alice);

        vm.prank(alice);
        col.redeem(alice, id, opened / 2, recipient, "");
        assertEq(IERC20(t0).balanceOf(alice), alice0Before, "partial redeem pays no token0 fee");
        assertEq(IERC20(t1).balanceOf(alice), alice1Before, "partial redeem pays no token1 fee");
        (uint256 owed0, uint256 owed1) = ad.feesOwed(alice, id);
        assertGt(owed0 + owed1, 0, "fees stay owed after partial redeem");

        uint256 rest = col.balanceOf(alice, id);
        vm.prank(alice);
        col.redeem(alice, id, rest, recipient, "");
        uint256 got0 = IERC20(t0).balanceOf(alice) - alice0Before;
        uint256 got1 = IERC20(t1).balanceOf(alice) - alice1Before;
        assertGt(got0 + got1, 0, "full redeem pays fees to account");
        (uint256 after0, uint256 after1) = ad.feesOwed(alice, id);
        assertEq(after0 + after1, 0, "nothing left owed after full redeem");
        _suiteCheckBooks();
    }

    function test_suite_seizeMovesUnitsAndBookmarks() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();

        uint256 seized = _suiteLiquidatePart(id);
        uint256 aliceLeft = col.balanceOf(alice, id);
        assertGt(seized, 0, "seized units");
        assertGt(aliceLeft, 0, "partial liquidation leaves borrower units");
        assertEq(col.balanceOf(carol, id), seized);
        assertEq(aliceLeft + seized, opened);
        assertEq(col.totalSupply(id), ad.units(id));

        if (_suiteHasSeparateFees()) {
            // Uncollected fees accrued before liquidation moved with the seized units' bookmarks
            vm.prank(carol);
            (uint256 c0, uint256 c1) = ad.collectFees(carol, id, carol);
            vm.prank(alice);
            (uint256 a0, uint256 a1) = ad.collectFees(alice, id, alice);
            assertGt(a0, 1_000, "borrower token0 fees large enough to check split");
            assertGt(c0, 1_000, "liquidator token0 fees large enough to check split");
            assertGt(a1, 1_000, "borrower token1 fees large enough to check split");
            assertGt(c1, 1_000, "liquidator token1 fees large enough to check split");
            assertApproxEqRel(c0 * aliceLeft, a0 * seized, 0.01e18, "token0 split by units");
            assertApproxEqRel(c1 * aliceLeft, a1 * seized, 0.01e18, "token1 split by units");
        }
        _suiteCheckBooks();
    }

    function test_suite_fullSeizeMovesAllFees() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();
        (uint256 owed0Before, uint256 owed1Before) = ad.feesOwed(alice, id);

        uint256 seized = _suiteLiquidateFull(id);
        assertEq(seized, opened, "full seize takes 100% of units");
        assertEq(col.balanceOf(alice, id), 0, "borrower left with 0 units");
        assertEq(col.balanceOf(carol, id), opened, "liquidator holds 100% of units");
        assertEq(col.totalSupply(id), ad.units(id));

        if (_suiteHasSeparateFees()) {
            vm.prank(alice);
            (uint256 a0, uint256 a1) = ad.collectFees(alice, id, alice);
            assertEq(a0 + a1, 0, "fully seized borrower collects no unclaimed fees");

            vm.prank(carol);
            (uint256 c0, uint256 c1) = ad.collectFees(carol, id, carol);
            assertGt(c0, 1_000, "liquidator collects all unclaimed token0 fees");
            assertGt(c1, 1_000, "liquidator collects all unclaimed token1 fees");
            assertGe(c0 + 2, owed0Before, "liquidator gets at least previewed token0 fees");
            assertGe(c1 + 2, owed1Before, "liquidator gets at least previewed token1 fees");
            (uint256 rem0, uint256 rem1) = ad.feesOwed(carol, id);
            assertEq(rem0 + rem1, 0);
        }
        _suiteCheckBooks();
    }

    function test_suite_seizeMovesCreditedFees() public {
        if (!_suiteHasSeparateFees()) return;
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();

        // Full seize after a 0.1% partial redeem (credits fees into checkpoint.owed without paying)
        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();
        uint256 sliver = opened / 1000;
        if (sliver == 0) sliver = 1;
        vm.prank(alice);
        col.redeem(alice, id, sliver, alice, "");
        (uint256 owed0Before, uint256 owed1Before) = ad.feesOwed(alice, id);
        assertGt(owed0Before, 1_000, "credited token0 fees before full seize");
        assertGt(owed1Before, 1_000, "credited token1 fees before full seize");

        _suiteLiquidateFull(id);
        assertEq(col.balanceOf(alice, id), 0, "full seize");
        (uint256 aLeft0, uint256 aLeft1) = ad.feesOwed(alice, id);
        assertEq(aLeft0 + aLeft1, 0, "borrower keeps none of credited fees on full seize");
        vm.prank(alice);
        (uint256 a0, uint256 a1) = ad.collectFees(alice, id, alice);
        assertEq(a0 + a1, 0, "borrower collects 0 after full seize");
        vm.prank(carol);
        (uint256 c0, uint256 c1) = ad.collectFees(carol, id, carol);
        assertGe(c0 + 2, owed0Before, "liquidator collects all credited token0 fees");
        assertGe(c1 + 2, owed1Before, "liquidator collects all credited token1 fees");

        // Partial seize after a 0.1% partial redeem: credited fees move pro rata
        (uint256 id2, uint256 opened2,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();
        uint256 sliver2 = opened2 / 1000;
        if (sliver2 == 0) sliver2 = 1;
        vm.prank(alice);
        col.redeem(alice, id2, sliver2, alice, "");
        uint256 aliceBefore = col.balanceOf(alice, id2);
        (uint256 p0Before, uint256 p1Before) = ad.feesOwed(alice, id2);
        assertGt(p0Before, 1_000);
        assertGt(p1Before, 1_000);

        uint256 seized = _suiteLiquidatePart(id2);
        uint256 aliceLeft = col.balanceOf(alice, id2);
        assertEq(aliceLeft + seized, aliceBefore);
        vm.prank(carol);
        (uint256 pc0, uint256 pc1) = ad.collectFees(carol, id2, carol);
        vm.prank(alice);
        (uint256 pa0, uint256 pa1) = ad.collectFees(alice, id2, alice);
        assertGt(pa0, 1_000, "borrower kept token0 credited fees");
        assertGt(pc0, 1_000, "liquidator got token0 credited fees");
        assertGt(pa1, 1_000, "borrower kept token1 credited fees");
        assertGt(pc1, 1_000, "liquidator got token1 credited fees");
        assertApproxEqRel(pc0 * aliceLeft, pa0 * seized, 0.01e18, "credited token0 split by units");
        assertApproxEqRel(pc1 * aliceLeft, pa1 * seized, 0.01e18, "credited token1 split by units");
        _suiteCheckBooks();
    }

    function test_suite_collectFeesAfterLiquidation() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();
        (address t0, address t1,,) = _suiteDepositTokens();

        (uint256 id,,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        _suiteGenerateFees();
        uint256 seized = _suiteLiquidatePart(id);
        assertGt(seized, 0);
        assertGt(col.balanceOf(alice, id), 0);
        _suiteGenerateFees();

        if (!_suiteHasSeparateFees()) {
            vm.prank(carol);
            (uint256 c0, uint256 c1) = ad.collectFees(carol, id, carol);
            assertEq(c0 + c1, 0);
            _suiteCheckBooks();
            return;
        }

        // Stranger cannot collect for carol
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__Unauthorized.selector);
        ad.collectFees(carol, id, stranger);

        uint256 carol0 = IERC20(t0).balanceOf(carol);
        uint256 carol1 = IERC20(t1).balanceOf(carol);
        vm.prank(carol);
        (uint256 gc0, uint256 gc1) = ad.collectFees(carol, id, carol);
        assertGt(gc0 + gc1, 0, "liquidator collects fees");
        assertEq(IERC20(t0).balanceOf(carol) - carol0, gc0);
        assertEq(IERC20(t1).balanceOf(carol) - carol1, gc1);

        uint256 alice0 = IERC20(t0).balanceOf(alice);
        uint256 alice1 = IERC20(t1).balanceOf(alice);
        vm.prank(alice);
        (uint256 ga0, uint256 ga1) = ad.collectFees(alice, id, alice);
        assertGt(ga0 + ga1, 0, "borrower collects fees");
        assertEq(IERC20(t0).balanceOf(alice) - alice0, ga0);
        assertEq(IERC20(t1).balanceOf(alice) - alice1, ga1);

        (uint256 lo0, uint256 lo1) = ad.feesOwed(carol, id);
        assertEq(lo0 + lo1, 0);
        (uint256 ao0, uint256 ao1) = ad.feesOwed(alice, id);
        assertEq(ao0 + ao1, 0);
        _suiteCheckBooks();
    }

    function test_suite_amountsAtMatchesRedeem() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        uint160 sqrtP = ad.poolSqrtPriceX96(id);
        uint160[5] memory prices = [sqrtP, sqrtP, sqrtP, sqrtP, sqrtP];

        uint256 half = opened / 2;
        (uint256[5] memory expHalf0, uint256[5] memory expHalf1) = ad.amountsAt(id, half, opened, prices);
        (uint256[5] memory expAll0, uint256[5] memory expAll1) = ad.amountsAt(id, opened, opened, prices);

        address recipient = makeAddr("amountsRecipient");
        vm.prank(alice);
        (uint256 got0, uint256 got1) = col.redeem(alice, id, half, recipient, "");
        _suiteAssertApprox(got0, expHalf0[0], "half redeem token0 matches amountsAt");
        _suiteAssertApprox(got1, expHalf1[0], "half redeem token1 matches amountsAt");

        vm.prank(alice);
        (uint256 rest0, uint256 rest1) = col.redeem(alice, id, opened - half, recipient, "");
        _suiteAssertApprox(got0 + rest0, expAll0[0], "full redeem token0 matches amountsAt");
        _suiteAssertApprox(got1 + rest1, expAll1[0], "full redeem token1 matches amountsAt");
        _suiteCheckBooks();
    }

    function test_suite_refunds() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        (address t0, address t1, uint256 a0, uint256 a1) = _suiteDepositTokens();

        // Lopsided open: 5x token0, 1x token1 -> excess token0 refunded to refundTo
        address refundOpen = makeAddr("refundOpen");
        (uint256 id,, uint256 used0, uint256 used1) = _suiteOpen(_suiteMintData(), refundOpen, 5, 1);
        assertGt(used0 + used1, 0);
        uint256 ref0 = IERC20(t0).balanceOf(refundOpen);
        uint256 ref1 = IERC20(t1).balanceOf(refundOpen);
        assertEq(ref0, a0 * 5 - used0, "open token0 refund exact");
        assertEq(ref1, a1 - used1, "open token1 refund exact");
        assertGt(ref0, 0, "open refunded excess token0");

        // Lopsided increase: 1x token0, 5x token1 -> excess token1 refunded to refundTo
        address refundInc = makeAddr("refundInc");
        deal(t0, alice, IERC20(t0).balanceOf(alice) + a0);
        deal(t1, alice, IERC20(t1).balanceOf(alice) + a1 * 5);
        vm.startPrank(alice);
        IERC20(t0).transfer(address(ad), a0);
        IERC20(t1).transfer(address(ad), a1 * 5);
        (uint256 added, uint256 incUsed0, uint256 incUsed1) = col.increaseLiquidity(alice, id, refundInc, "");
        vm.stopPrank();
        assertGt(added, 0);
        assertEq(IERC20(t0).balanceOf(refundInc), a0 - incUsed0, "increase token0 refund exact");
        assertEq(IERC20(t1).balanceOf(refundInc), a1 * 5 - incUsed1, "increase token1 refund exact");
        assertGt(IERC20(t1).balanceOf(refundInc), 0, "increase refunded excess token1");
        _suiteCheckBooks();
    }

    function test_suite_nativeEthReportedAndPaidAsWeth() public {
        address weth = _suiteNativeEthWeth();
        if (weth == address(0)) return;
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        (address t0, address t1) = ad.tokens(id);
        assertTrue(t0 == weth || t1 == weth, "native ETH reported as WETH");
        assertEq(address(ad).balance, 0, "no raw ETH left in adapter after open");

        _suiteGenerateFees();
        address feeRecipient = makeAddr("nativeEthFeeRecipient");
        vm.prank(alice);
        (uint256 f0, uint256 f1) = ad.collectFees(alice, id, feeRecipient);
        assertGt(t0 == weth ? f0 : f1, 0, "native ETH fees paid as WETH");
        assertEq(IERC20(weth).balanceOf(feeRecipient), t0 == weth ? f0 : f1);
        assertEq(feeRecipient.balance, 0, "fees paid as WETH, not raw ETH");

        address redeemRecipient = makeAddr("nativeEthRedeemRecipient");
        vm.prank(alice);
        (uint256 out0, uint256 out1) = col.redeem(alice, id, opened, redeemRecipient, "");
        assertGt(t0 == weth ? out0 : out1, 0, "native ETH principal paid as WETH");
        assertEq(IERC20(weth).balanceOf(redeemRecipient), t0 == weth ? out0 : out1);
        assertEq(redeemRecipient.balance, 0, "principal paid as WETH, not raw ETH");
        assertEq(address(ad).balance, 0, "no raw ETH left in adapter");
        _suiteCheckBooks();
    }

    function test_suite_onlyCollateralCanCallCoreHooks() public {
        ISenzuAdapter ad = _suiteAdapter();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();
        (uint256 id,,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        bytes memory mintData = _suiteMintData();

        vm.startPrank(alice);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        ad.deposit(999, alice, alice, mintData);

        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        ad.increaseLiquidity(id, alice, 1, alice, "");

        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        ad.decreaseLiquidity(id, 1, alice, 1, alice, "");

        vm.expectRevert(ISenzuAdapter.SenzuAdapter__NotCollateral.selector);
        ad.seize(id, alice, carol, 0, 1);
        vm.stopPrank();
    }
}

/**
 *  @title  RewardsAdapterSuite
 *  @notice Extension of `AdapterSuite` for reward-paying adapters implementing `ISenzuRewardsAdapter`.
 */
abstract contract RewardsAdapterSuite is AdapterSuite {
    /*  ================================================
                            Hooks
        ================================================  */

    function _suiteRewardsAdapter() internal view virtual returns (ISenzuRewardsAdapter) {
        return ISenzuRewardsAdapter(address(_suiteAdapter()));
    }

    function _suiteRewardLedger() internal view virtual returns (RewardLedger) {
        return RewardLedger(address(_suiteAdapter()));
    }

    function _suiteIsStaked(uint256 id) internal view virtual returns (bool);

    function _suiteMintDataStaked() internal view virtual returns (bytes memory);

    function _suiteAccrueRewards(uint256 id) internal virtual;

    /// @dev Lists the reward-token pool if needed and returns its unstaked mint data and deposit tokens/amounts
    function _suiteRewardTokenPoolSetup()
        internal
        virtual
        returns (bytes memory mintData, address token0, address token1, uint256 amount0, uint256 amount1);

    /// @dev Swaps in the reward-token pool to accrue fees in the reward token
    function _suiteSwapRewardTokenPool() internal virtual;

    /*  ================================================
                            Tests
        ================================================  */

    function test_suite_stakeAndUnstake() public {
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        (address t0, address t1,,) = _suiteDepositTokens();
        address reward = ledger.rewardToken();

        (uint256 id,,,) = _suiteOpen(_suiteMintData(), alice, 1, 1);
        assertFalse(_suiteIsStaked(id), "opened unstaked");
        _suiteGenerateFees();

        // Unauthorized caller cannot toggle stake
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__Unauthorized.selector);
        rad.setStake(alice, id, true);

        // Stake: pays unstaked fees in the same call
        uint256 a0 = IERC20(t0).balanceOf(alice);
        uint256 a1 = IERC20(t1).balanceOf(alice);
        vm.prank(alice);
        rad.setStake(alice, id, true);
        assertTrue(_suiteIsStaked(id), "staked");
        assertGt((IERC20(t0).balanceOf(alice) - a0) + (IERC20(t1).balanceOf(alice) - a1), 0, "stake paid fees");
        (uint256 f0, uint256 f1) = _suiteAdapter().feesOwed(alice, id);
        assertEq(f0 + f1, 0);

        // Unstake: pays staked rewards in the same call
        _suiteAccrueRewards(id);
        uint256 rBefore = IERC20(reward).balanceOf(alice);
        vm.prank(alice);
        rad.setStake(alice, id, false);
        assertFalse(_suiteIsStaked(id), "unstaked");
        assertGt(IERC20(reward).balanceOf(alice) - rBefore, 0, "unstake paid rewards");
        assertEq(ledger.rewardsOwed(alice, id), 0);
        _suiteCheckBooks();
    }

    function test_suite_claimRewards() public {
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        address reward = ledger.rewardToken();

        (uint256 id,,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        assertTrue(_suiteIsStaked(id), "opened staked");
        _suiteAccrueRewards(id);

        uint256 owed = ledger.rewardsOwed(alice, id);
        assertGt(owed, 0, "rewards accrued");

        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(ISenzuAdapter.SenzuAdapter__Unauthorized.selector);
        rad.claimRewards(alice, id, stranger);

        address recipient = makeAddr("rewardRecipient");
        vm.prank(alice);
        uint256 paid = rad.claimRewards(alice, id, recipient);
        assertGt(paid, 0, "claimed rewards");
        assertApproxEqAbs(paid, owed, 2, "paid matches rewardsOwed");
        assertEq(IERC20(reward).balanceOf(recipient), paid);
        assertEq(ledger.rewardsOwed(alice, id), 0);
        _suiteCheckBooks();
    }

    function test_suite_rewardsAfterLiquidation() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();
        address reward = ledger.rewardToken();

        (uint256 id,,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        assertTrue(_suiteIsStaked(id));
        _suiteAccrueRewards(id);

        uint256 seized = _suiteLiquidatePart(id);
        assertGt(seized, 0);
        assertGt(col.balanceOf(alice, id), 0);
        assertGt(ledger.rewardsOwed(carol, id), 0, "unbooked rewards moved with seized units");
        assertGt(ledger.rewardsOwed(alice, id), 0, "borrower kept rewards on remaining units");

        _suiteAccrueRewards(id);
        uint256 carolOwed = ledger.rewardsOwed(carol, id);
        uint256 aliceOwed = ledger.rewardsOwed(alice, id);

        uint256 carolR = IERC20(reward).balanceOf(carol);
        vm.prank(carol);
        uint256 carolPaid = rad.claimRewards(carol, id, carol);
        assertApproxEqAbs(carolPaid, carolOwed, 2, "liquidator claimed owed rewards");
        assertEq(IERC20(reward).balanceOf(carol) - carolR, carolPaid);

        uint256 aliceR = IERC20(reward).balanceOf(alice);
        vm.prank(alice);
        uint256 alicePaid = rad.claimRewards(alice, id, alice);
        assertApproxEqAbs(alicePaid, aliceOwed, 2, "borrower claimed owed rewards");
        assertEq(IERC20(reward).balanceOf(alice) - aliceR, alicePaid);
        assertEq(ledger.rewardsOwed(carol, id), 0);
        assertEq(ledger.rewardsOwed(alice, id), 0);

        // Rewards paid only on full redeem, to the account (never `to`)
        _suiteAccrueRewards(id);
        address recipient = makeAddr("rewardRedeemRecipient");
        carolR = IERC20(reward).balanceOf(carol);
        vm.prank(carol);
        col.redeem(carol, id, seized / 2, recipient, "");
        assertEq(IERC20(reward).balanceOf(carol), carolR, "partial redeem pays no rewards");

        uint256 carolLeft = col.balanceOf(carol, id);
        vm.prank(carol);
        col.redeem(carol, id, carolLeft, recipient, "");
        assertGt(IERC20(reward).balanceOf(carol) - carolR, 0, "full redeem pays rewards to account");
        assertEq(IERC20(reward).balanceOf(recipient), 0, "rewards never go to redeem recipient");
        assertEq(ledger.rewardsOwed(carol, id), 0);
        _suiteCheckBooks();
    }

    function test_suite_fullSeizeMovesAllRewards() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();

        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        assertTrue(_suiteIsStaked(id));
        _suiteAccrueRewards(id);
        uint256 owedBefore = ledger.rewardsOwed(alice, id);
        assertGt(owedBefore, 0);

        uint256 seized = _suiteLiquidateFull(id);
        assertEq(seized, opened, "full seize takes 100% of units");
        assertEq(col.balanceOf(alice, id), 0);
        assertEq(col.balanceOf(carol, id), opened);
        assertEq(ledger.rewardsOwed(alice, id), 0, "borrower left with 0 unclaimed rewards");
        assertApproxEqAbs(ledger.rewardsOwed(carol, id), owedBefore, 2, "liquidator inherits all unclaimed rewards");

        vm.prank(alice);
        assertEq(rad.claimRewards(alice, id, alice), 0, "fully seized borrower claims 0");
        vm.prank(carol);
        uint256 carolPaid = rad.claimRewards(carol, id, carol);
        assertApproxEqAbs(carolPaid, owedBefore, 2, "liquidator claims all rewards");
        assertEq(ledger.rewardsOwed(carol, id), 0);
        _suiteCheckBooks();
    }

    function test_suite_seizeMovesCreditedRewards() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();

        // Full seize after a 0.1% partial redeem (credits rewards into rewardCheckpoints.owed without paying)
        (uint256 id, uint256 opened,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        _suiteAccrueRewards(id);
        uint256 sliver = opened / 1000;
        if (sliver == 0) sliver = 1;
        vm.prank(alice);
        col.redeem(alice, id, sliver, alice, "");
        uint256 owedBefore = ledger.rewardsOwed(alice, id);
        assertGt(owedBefore, 1_000, "credited rewards before full seize");

        _suiteLiquidateFull(id);
        assertEq(col.balanceOf(alice, id), 0, "full seize");
        assertEq(ledger.rewardsOwed(alice, id), 0, "borrower keeps none of credited rewards on full seize");
        assertApproxEqAbs(ledger.rewardsOwed(carol, id), owedBefore, 2, "liquidator gets all credited rewards");
        vm.prank(alice);
        assertEq(rad.claimRewards(alice, id, alice), 0, "borrower claims 0 after full seize");
        vm.prank(carol);
        uint256 carolPaid = rad.claimRewards(carol, id, carol);
        assertApproxEqAbs(carolPaid, owedBefore, 2, "liquidator claims all credited rewards");

        // Partial seize after a 0.1% partial redeem: credited rewards move pro rata
        (uint256 id2, uint256 opened2,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        _suiteAccrueRewards(id2);
        uint256 sliver2 = opened2 / 1000;
        if (sliver2 == 0) sliver2 = 1;
        vm.prank(alice);
        col.redeem(alice, id2, sliver2, alice, "");
        uint256 aliceBefore = col.balanceOf(alice, id2);
        uint256 pBefore = ledger.rewardsOwed(alice, id2);
        assertGt(pBefore, 1_000);

        uint256 seized = _suiteLiquidatePart(id2);
        uint256 aliceLeft = col.balanceOf(alice, id2);
        assertEq(aliceLeft + seized, aliceBefore);
        vm.prank(carol);
        uint256 pc = rad.claimRewards(carol, id2, carol);
        vm.prank(alice);
        uint256 pa = rad.claimRewards(alice, id2, alice);
        assertGt(pa, 1_000, "borrower kept credited rewards");
        assertGt(pc, 1_000, "liquidator got credited rewards");
        assertApproxEqRel(pc * aliceLeft, pa * seized, 0.01e18, "credited rewards split by units");
        _suiteCheckBooks();
    }

    function test_suite_rewardTokenPoolKeepsRewardsAndFeesApart() public {
        SenzuCollateral col = _suiteCollateral();
        ISenzuAdapter ad = _suiteAdapter();
        ISenzuRewardsAdapter rad = _suiteRewardsAdapter();
        RewardLedger ledger = _suiteRewardLedger();
        address alice = _suiteAlice();
        address carol = _suiteLiquidator();
        address reward = ledger.rewardToken();

        // Book rewards on a staked position first
        (uint256 stakedId,,,) = _suiteOpen(_suiteMintDataStaked(), alice, 1, 1);
        _suiteAccrueRewards(stakedId);
        vm.prank(alice);
        col.redeem(alice, stakedId, 1, alice, "");
        uint256 stakedOwed = ledger.rewardsOwed(alice, stakedId);
        assertGt(stakedOwed, 0, "staked position has booked rewards");

        // Open an unstaked position in a pool containing the reward token
        (bytes memory mintData, address rt0, address rt1, uint256 ra0, uint256 ra1) = _suiteRewardTokenPoolSetup();
        assertTrue(rt0 == reward || rt1 == reward, "pool contains reward token");
        deal(rt0, carol, IERC20(rt0).balanceOf(carol) + ra0);
        deal(rt1, carol, IERC20(rt1).balanceOf(carol) + ra1);
        vm.startPrank(carol);
        IERC20(rt0).transfer(address(ad), ra0);
        IERC20(rt1).transfer(address(ad), ra1);
        (uint256 rewardPoolId,,,,,) = col.open(carol, carol, mintData);
        vm.stopPrank();
        assertGe(ledger.rewardsOwed(alice, stakedId), stakedOwed, "deposit did not touch staked rewards");

        // Swap in the reward-token pool and collect swap fees in the reward token
        _suiteSwapRewardTokenPool();
        uint256 carolBefore = IERC20(reward).balanceOf(carol);
        vm.prank(carol);
        (uint256 f0, uint256 f1) = ad.collectFees(carol, rewardPoolId, carol);
        uint256 rewardFee = rt0 == reward ? f0 : f1;
        assertGt(rewardFee, 0, "swap fees collected in reward token");
        assertEq(IERC20(reward).balanceOf(carol) - carolBefore, rewardFee);

        // Close the reward-token pool position, then verify Alice still claims 100% of her staked rewards
        uint256 carolUnits = col.balanceOf(carol, rewardPoolId);
        vm.prank(carol);
        col.redeem(carol, rewardPoolId, carolUnits, carol, "");
        vm.prank(alice);
        uint256 alicePaid = rad.claimRewards(alice, stakedId, alice);
        assertGe(alicePaid + 2, stakedOwed, "staked rewards paid in full");
        _suiteCheckBooks();
    }
}
