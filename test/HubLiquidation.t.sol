// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HealthMath} from "../src/libraries/HealthMath.sol";
import {LiquidationLogic} from "../src/libraries/LiquidationLogic.sol";
import {HealthResult, lenderId} from "../src/libraries/Types.sol";
import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {badDebtIn} from "./utils/Logs.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";

contract HubLiquidationTest is HubFixture {
    uint256 debt; // Alice's USDC debt

    function setUp() public override {
        super.setUp();
        // Penalty and seizure math without the protocol's liquidation fee (LiquidationFee.t.sol covers the fee)
        riskConfig.setLiquidationFee(address(adapter), 0);

        // Alice borrows 80% of her collateral in USDC (the max with the borrow buffer is about 83%)
        debt = _usdcFor(0.8e18);
        _borrow(ALICE, address(usdc), debt);

        // Carol is the liquidator
        usdc.mint(CAROL, 1_000_000e6);
        weth.mint(CAROL, 1_000e18);
        vm.startPrank(CAROL);
        usdc.approve(address(borrowable), type(uint256).max);
        weth.approve(address(borrowable), type(uint256).max);
        vm.stopPrank();
    }

    function _setEthPrice(int256 price) internal {
        ethFeed.set(price, block.timestamp);
    }

    function _liquidate(address asset, uint256 amount) internal returns (uint256 seized) {
        vm.prank(CAROL);
        (seized,) = lockLiquidator().liquidate(collateral, ALICE, id, asset, amount, CAROL);
    }

    function _assertBalancesSumToSupply() internal view {
        assertEq(
            collateral.balanceOf(ALICE, id) + collateral.balanceOf(CAROL, id) + collateral.balanceOf(DAO, id)
                + collateral.balanceOf(BOB, id),
            collateral.totalSupply(id)
        );
    }

    /*  ================================================
                          Eligibility
        ================================================  */

    function test_healthyPositionCantBeLiquidated() public {
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        vm.prank(CAROL);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLiquidatable.selector);
        lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), type(uint256).max, CAROL);
    }

    function test_smallDropIsNotLiquidatable() public {
        _setEthPrice(1800e8); // -10%: LTV about 84%, threshold about 87%
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
    }

    function test_marketWithoutDebtReverts() public {
        _setEthPrice(1600e8);
        vm.prank(CAROL);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NoDebt.selector);
        lockLiquidator().liquidate(collateral, ALICE, id, address(weth), type(uint256).max, CAROL);
    }

    function test_zeroRepayReverts() public {
        _setEthPrice(1600e8);
        vm.prank(CAROL);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__ZeroAmount.selector);
        lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), 0, CAROL);
    }

    /// @dev A debt outside the pair, in an 18-decimal token at $3 with its own 10% penalty (the pair's is 5%), is
    ///      repaid at its own price and decimals: the value seized is the value repaid times that penalty
    function test_debtOutsideThePair_seizedAtItsOwnPriceAndDecimals() public {
        MockERC20 dai = new MockERC20("DAI", 18);
        oracle.addFeed(address(dai), address(new MockAggregator(8, 3e8)), 1 days);
        borrowable.createMarket(address(dai), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(dai), 1.05e18, 1.1e18, false);
        riskConfig.setLiquid(address(adapter), address(dai));
        dai.mint(CAROL, 100_000e18);
        vm.startPrank(CAROL);
        dai.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(dai), 50_000e18, CAROL);
        vm.stopPrank();

        uint256 bobId = _open(BOB, L);
        vm.prank(BOB);
        collateral.borrow(BOB, bobId, address(dai), 2_000e18, BOB); // $6,000 of ~$8,944
        _setEthPrice(1200e8);
        assertTrue(collateral.health(BOB, bobId).minSurplusUsdWad < 0);

        HealthResult memory before = collateral.health(BOB, bobId);
        assertGt(before.collateralUsdWad * 1e18 / before.debtUsdWad, 1.1e18, "the full 10% penalty is bearable");
        uint256 units = collateral.balanceOf(BOB, bobId);

        vm.prank(CAROL);
        (uint256 seized, uint256 repaid) =
            lockLiquidator().liquidate(collateral, BOB, bobId, address(dai), 1_000e18, CAROL);

        assertEq(repaid, 1_000e18);
        uint256 seizedUsd = seized * before.collateralUsdWad / units;
        uint256 repaidUsd = repaid * 3e18 / 1e18;
        assertApproxEqRel(seizedUsd * 1e18 / repaidUsd, 1.1e18, 1e15, "seized = repaid x the debt's own penalty");
    }

    /*  ================================================
                        Liquidation size
        ================================================  */

    /// @dev No close factor: ALL repays the whole debt, even of a position that is not underwater
    function test_liquidation_wholeDebtAndIncentive() public {
        _setEthPrice(1600e8); // -20%: LTV about 89%
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        HealthResult memory before = collateral.health(ALICE, id);
        uint256 carolUsdc = usdc.balanceOf(CAROL);

        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        uint256 repaid = carolUsdc - usdc.balanceOf(CAROL);

        // Not underwater (collateral > debt · penalty), and still the whole debt
        assertGt(before.collateralUsdWad, before.debtUsdWad * 105 / 100);
        assertApproxEqAbs(repaid, debt, 1);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);

        // Carol gets repay · 1.05 worth of liquidity, all of the penalty; the protocol takes nothing
        uint256 repaidUsd = repaid * 1e12;
        assertApproxEqRel(seized * before.collateralUsdWad / L, repaidUsd * 105 / 100, 1e12);
        assertEq(collateral.balanceOf(CAROL, id), seized);
        assertEq(collateral.balanceOf(DAO, id), 0, "nothing to protocolReserves");

        // The borrower keeps the rest
        assertGt(collateral.balanceOf(ALICE, id), 0);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        _assertBalancesSumToSupply();
        _assertSupplyMatchesAdapter(id);
    }

    function test_partialLiquidation_repayBelowCap() public {
        _setEthPrice(1600e8);
        uint256 carolUsdc = usdc.balanceOf(CAROL);
        _liquidate(address(usdc), 100e6);
        assertEq(carolUsdc - usdc.balanceOf(CAROL), 100e6);
    }

    function test_liquidatorCanRedeemSeizedLiquidity() public {
        _setEthPrice(1600e8);
        uint256 seized = _liquidate(address(usdc), type(uint256).max);

        vm.prank(CAROL);
        collateral.redeem(CAROL, id, seized, CAROL, "");
        assertEq(collateral.balanceOf(CAROL, id), 0);
        _assertSupplyMatchesAdapter(id);
    }

    function test_tiedDebt_liquidatableWhenCollateralTokenPumps() public {
        // Fresh position with WETH debt only
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        vm.stopPrank();
        uint256 wethDebt = _collateralUsd() * 0.8e18 / 1e18 / 2000;
        _borrow(ALICE, address(weth), wethDebt);

        // ETH +30%: debt grows 1.3x, full-range collateral only about 1.14x
        _setEthPrice(2600e8);
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        uint256 carolWeth = weth.balanceOf(CAROL);
        _liquidate(address(weth), type(uint256).max);
        assertApproxEqAbs(carolWeth - weth.balanceOf(CAROL), wethDebt, 1, "the whole debt");
    }

    /*  ================================================
                    Underwater and bad debt
        ================================================  */

    /// @dev Collateral between 1.02x and 1.05x the debt: the liquidator takes everything and repays the whole debt
    ///      (a 2-5% bonus), so lenders lose nothing. Before (audit 2026-10-15) the repay shrank to
    ///      collateral / 1.06 and the rest was written off, even though the collateral covered the debt; a borrower
    ///      liquidating itself from a second account kept the difference
    function test_fullSeize_collateralCoversTheDebt_repaysItAll() public {
        _setEthPrice(1384e8); // collateral about 1.04x the debt
        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.collateralUsdWad, h.debtUsdWad * 102 / 100);
        assertLt(h.collateralUsdWad, h.debtUsdWad * 105 / 100);

        uint256 carolUsdc = usdc.balanceOf(CAROL);
        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        uint256 repaid = carolUsdc - usdc.balanceOf(CAROL);

        // Everything, but for at most one unit: the bearable ratio rounds down, so a seize never takes more than it
        // pays for, and the borrower (now debt-free) keeps the dust
        assertGe(seized, L - 1, "everything to the liquidator");
        assertEq(collateral.balanceOf(DAO, id), 0, "nothing to protocolReserves");
        assertApproxEqAbs(repaid, debt, 1, "the whole debt");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0, "nothing left to write off");
        _assertBalancesSumToSupply();
    }

    /// @dev Audit 2026-10-15 (found writing the invariant tests): at collateral 1.04x the debt, a liquidator repaid 90%
    ///      at the full penalty, which left the rest underwater (0.86x), then liquidated that and wrote off about
    ///      1.6% of the debt, earning more than one full liquidation would. The penalty now shrinks to what the
    ///      position bears, so any split repays the whole debt
    function test_partialLiquidations_leaveNoBadDebtOnACoveredPosition() public {
        _setEthPrice(1384e8); // collateral about 1.04x the debt
        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.collateralUsdWad, h.debtUsdWad * 102 / 100);

        uint256 carolUsdc = usdc.balanceOf(CAROL);
        _liquidate(address(usdc), debt * 9 / 10);
        HealthResult memory mid = collateral.health(ALICE, id);
        _assertRatioHeld(h, mid);

        _liquidate(address(usdc), type(uint256).max);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0, "the whole debt repaid: nothing to write off");
        uint256 repaid = carolUsdc - usdc.balanceOf(CAROL);
        assertApproxEqAbs(repaid, debt, 2);

        // The liquidator took at most the collateral: what it got is worth no more than collateral / debt × repaid
        uint256 takenUsd = collateral.balanceOf(CAROL, id) * h.collateralUsdWad / L;
        assertLe(takenUsd, h.collateralUsdWad + 1e12);
        _assertBalancesSumToSupply();
    }

    /// @dev Over collateral 1.02x the debt, no liquidation of any size lowers collateral / debt: lenders lose nothing
    function testFuzz_liquidationNeverLowersACoveredRatio(uint256 ethPrice, uint256 repayAmount) public {
        _setEthPrice(int256(bound(ethPrice, 1290e8, 1750e8)));
        if (collateral.health(ALICE, id).minSurplusUsdWad >= 0) return;
        HealthResult memory before = collateral.health(ALICE, id);
        if (before.collateralUsdWad < before.debtUsdWad * 102 / 100) return;

        _liquidate(address(usdc), bound(repayAmount, 1e6, debt));
        HealthResult memory after_ = collateral.health(ALICE, id);
        if (after_.debtUsdWad == 0) return;
        _assertRatioHeld(before, after_);
    }

    /// @dev after.collateral / after.debt >= before.collateral / before.debt, to the valuation's own rounding only:
    ///      collateral counts each pool token in whole units, rounded down (under one USDC unit plus one wei of ETH,
    ///      < 2e12 in USD wad), and debt rounds up to a whole USDC unit (1e12)
    function _assertRatioHeld(HealthResult memory before, HealthResult memory after_) internal pure {
        uint256 debtAfter = after_.debtUsdWad > 1e12 ? after_.debtUsdWad - 1e12 : 0;
        assertGe(
            (after_.collateralUsdWad + 2e12) * before.debtUsdWad,
            before.collateralUsdWad * debtAfter,
            "collateral / debt went down"
        );
    }

    /// @dev Collateral below 1.02x the debt: the liquidator still takes everything for collateral / 1.02 (the
    ///      bonus at its 2% floor), and the same call writes off the rest: nothing backs it any more
    function test_underwater_takesEverythingAndWritesOffTheRest() public {
        _setEthPrice(1300e8); // collateral about 1.01x the debt
        HealthResult memory h = collateral.health(ALICE, id);
        assertLt(h.collateralUsdWad, h.debtUsdWad * 102 / 100);
        uint256 owed = borrowable.debtOf(ALICE, id, address(usdc));

        uint256 carolUsdc = usdc.balanceOf(CAROL);
        vm.recordLogs();
        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        uint256 repaid = carolUsdc - usdc.balanceOf(CAROL);

        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertEq(seized, L, "everything to the liquidator");
        assertEq(collateral.balanceOf(DAO, id), 0, "nothing to protocolReserves on bad debt");

        // Repay shrank to collateral / 1.02; the rest was written off in the liquidation
        assertApproxEqRel(repaid * 1e12, h.collateralUsdWad * 100 / 102, 1e12);
        assertFalse(borrowable.hasDebt(ALICE, id), "no bad debt waits for a write-off");
        assertApproxEqAbs(badDebtIn(vm.getRecordedLogs(), address(borrowable), address(usdc)), owed - repaid, 1);
        _assertBalancesSumToSupply();
    }

    /// @dev Nothing is left for resolveBadDebt after a full seize, and the liquidator redeems the whole position
    function test_badDebt_nothingLeftToResolveAfterAFullSeize() public {
        _setEthPrice(1300e8);
        _liquidate(address(usdc), type(uint256).max);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NoDebt.selector);
        collateral.resolveBadDebt(ALICE, id);

        uint256 units = collateral.balanceOf(CAROL, id);
        assertEq(units, collateral.totalSupply(id), "the liquidator holds it all");
        vm.prank(CAROL);
        collateral.redeem(CAROL, id, units, CAROL, "");
        assertEq(collateral.totalSupply(id), 0);
    }

    /// @dev After a full seize a lender can't leave ahead of the loss: the share price falls in the liquidation itself
    function test_badDebt_lendersCantWithdrawAheadOfTheLoss() public {
        uint256 usdcId = lenderId(address(usdc));
        uint256 pricePerShare = borrowable.convertToAssets(address(usdc), 1e18);
        _setEthPrice(1300e8);
        _liquidate(address(usdc), type(uint256).max);
        assertLt(borrowable.convertToAssets(address(usdc), 1e18), pricePerShare, "the loss is in the share price");
        uint256 bobShares = borrowable.balanceOf(BOB, usdcId);
        assertLt(
            borrowable.convertToAssets(address(usdc), bobShares),
            pricePerShare * bobShares / 1e18,
            "what Bob withdraws now already counts the loss"
        );
    }

    /// @dev The write-off needs the last unit. A liquidator that stops just short leaves the loss on the books, as
    ///      before any liquidation, so a lender can still leave at the old share price; anyone takes the rest for a
    ///      liquidation of what it is worth and the loss lands then (Morpho Blue the same, with collateral)
    function test_badDebt_aLiquidationStoppingShortLeavesTheLossWaiting() public {
        uint256 pricePerShare = borrowable.convertToAssets(address(usdc), 1e18);
        _setEthPrice(1300e8);
        HealthResult memory h = collateral.health(ALICE, id);
        uint256 all = h.collateralUsdWad * 100 / 102 / 1e12;

        _liquidate(address(usdc), all - all / 1e6);
        uint256 left = collateral.balanceOf(ALICE, id);
        assertGt(left, 0, "units left");
        assertLt(left, L / 1e5, "dust");
        assertTrue(borrowable.hasDebt(ALICE, id), "the loss waits");
        assertGe(borrowable.convertToAssets(address(usdc), 1e18), pricePerShare, "no loss in the share price yet");

        _liquidate(address(usdc), type(uint256).max);
        assertEq(collateral.balanceOf(ALICE, id), 0);
        assertFalse(borrowable.hasDebt(ALICE, id), "written off with the last unit");
        assertLt(borrowable.convertToAssets(address(usdc), 1e18), pricePerShare, "the loss is in the share price");
    }

    function test_badDebt_socializedProRataIncludingDaoShares() public {
        // The DAO holds 250,000 USDC of supply shares next to Bob's 1,000,000
        usdc.mint(DAO, 250_000e6);
        vm.startPrank(DAO);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(usdc), 250_000e6, DAO);
        vm.stopPrank();

        uint256 usdcId = lenderId(address(usdc));
        uint256 bobBefore = borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId));
        uint256 daoBefore = borrowable.convertToAssets(address(usdc), borrowable.balanceOf(DAO, usdcId));

        _setEthPrice(1300e8);
        uint256 owed = borrowable.debtOf(ALICE, id, address(usdc));
        uint256 carolUsdc = usdc.balanceOf(CAROL);
        vm.recordLogs();
        _liquidate(address(usdc), type(uint256).max);
        uint256 remaining = owed - (carolUsdc - usdc.balanceOf(CAROL));

        assertFalse(borrowable.hasDebt(ALICE, id));
        assertApproxEqAbs(badDebtIn(vm.getRecordedLogs(), address(borrowable), address(usdc)), remaining, 1);

        // Both lose the same fraction: the DAO isn't a first-loss backstop
        uint256 bobLoss = bobBefore - borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId));
        uint256 daoLoss = daoBefore - borrowable.convertToAssets(address(usdc), borrowable.balanceOf(DAO, usdcId));
        assertApproxEqAbs(bobLoss + daoLoss, remaining, 2);
        assertApproxEqRel(bobLoss * 1e18 / bobBefore, daoLoss * 1e18 / daoBefore, 1e12);
    }

    function test_badDebt_socializedToTheOnlyLender() public {
        uint256 usdcId = lenderId(address(usdc));
        uint256 bobBefore = borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId));

        _setEthPrice(1300e8);
        uint256 owed = borrowable.debtOf(ALICE, id, address(usdc));
        uint256 carolUsdc = usdc.balanceOf(CAROL);
        _liquidate(address(usdc), type(uint256).max);
        uint256 remaining = owed - (carolUsdc - usdc.balanceOf(CAROL));

        // Bob (the only lender) absorbs it, in the liquidation
        assertApproxEqAbs(
            borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId)), bobBefore - remaining, 2
        );

        // Cash didn't move: the write-off removed the same amount from supply and borrows
        assertEq(borrowable.getMarket(address(usdc)).totalBorrowAssets, 0);
    }

    function test_badDebt_needsNoCollateral() public {
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__CollateralRemaining.selector);
        collateral.resolveBadDebt(ALICE, id);
    }

    function test_badDebt_needsDebt() public {
        // Carol holds no liquidity and owes nothing in this position
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NoDebt.selector);
        collateral.resolveBadDebt(CAROL, id);
    }

    /*  ================================================
                              Fuzz
        ================================================  */

    /// @notice For any crash and repay size: the liquidator never gets more than repay · penalty (plus rounding),
    ///         liquidity is conserved, and debt only goes down by what was repaid, unless every unit was taken (then
    ///         the rest is written off)
    function testFuzz_liquidationBounds(uint256 ethPrice, uint256 repayAmount) public {
        ethPrice = bound(ethPrice, 1000e8, 1750e8);
        repayAmount = bound(repayAmount, 1e6, debt * 2);
        _setEthPrice(int256(ethPrice));
        if (collateral.health(ALICE, id).minSurplusUsdWad >= 0) return;

        HealthResult memory before = collateral.health(ALICE, id);
        uint256 carolUsdc = usdc.balanceOf(CAROL);
        uint256 seized = _liquidate(address(usdc), repayAmount);
        uint256 repaid = carolUsdc - usdc.balanceOf(CAROL);

        assertLe(repaid, repayAmount);
        // At most the 1.05 penalty, and at least the 2% floor when everything is taken
        assertLe(seized * before.collateralUsdWad / L, repaid * 1e12 * 105 / 100 + 1e12);
        if (seized == L) assertGe(before.collateralUsdWad + 2e12, repaid * 1e12 * 102 / 100); // repay rounds up
        if (seized == L) assertFalse(borrowable.hasDebt(ALICE, id), "a full seize writes off the rest");
        else assertApproxEqAbs(borrowable.debtOf(ALICE, id, address(usdc)), debt - repaid, 2);
        _assertBalancesSumToSupply();
        _assertSupplyMatchesAdapter(id);
    }

    /*  ================================================
                           pool price
        ================================================  */

    /// @dev Liquidation only moves units at oracle prices, so a pool pushed far from the oracle can't block it
    function test_liquidationIgnoresThePoolPrice() public {
        _setEthPrice(1600e8);
        adapter.setPoolSqrtPrice(HealthMath.sqrtPriceX96FromUsd(3000e18, 1e18, 18, 6)); // pool 87% above the oracle

        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        assertGt(seized, 0);
        _assertBalancesSumToSupply();
    }

    /*  ================================================
                        Audit 2026-10-06
        ================================================  */

    /// @dev Audit 2026-10-06: each seize poked the adapter, which collects fees in both pool tokens, so one paused pool
    ///      token blocked every liquidation of v4 and Ekubo positions. A seize never pokes: it moves the seized units'
    ///      fee bookmark (2026-11-22), so whether a poke would fail changes nothing. Audit 2026-10-15's liquidator,
    ///      who failed the poke on purpose to take fees the borrower hadn't collected, gets exactly the seized units'
    ///      share of them, as every liquidator does
    function test_liquidation_seizedUnitsTakeTheirUncollectedFees() public {
        adapter.accrueFees(id, 1e18, 100e6); // earned by Alice alone, not collected
        _setEthPrice(1600e8);
        adapter.setPokeReverts(true);
        uint256 units = collateral.balanceOf(ALICE, id);
        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        assertGt(seized, 0);

        adapter.setPokeReverts(false);
        uint256 carolWeth = weth.balanceOf(CAROL);
        vm.prank(CAROL);
        adapter.collectFees(CAROL, id, CAROL);
        assertApproxEqAbs(weth.balanceOf(CAROL) - carolWeth, 1e18 * seized / units, 10, "the seized units' share");

        vm.prank(ALICE);
        adapter.collectFees(ALICE, id, ALICE);
        assertApproxEqAbs(weth.balanceOf(ALICE), 1e18 * (units - seized) / units, 10, "the units she kept");
    }

    function test_liquidation_survivesAFailingFeePoke() public {
        uint256 lpId = id;
        adapter.accrueFees(lpId, 1e18, 100e6);
        _setEthPrice(1600e8);
        adapter.setPokeReverts(true);

        uint256 seized = _liquidate(address(usdc), type(uint256).max);
        assertGt(seized, 0);
        _assertBalancesSumToSupply();

        // The token moves again: every holder collects, and together they never take more than the position earned
        adapter.setPokeReverts(false);
        address[3] memory holders = [ALICE, CAROL, DAO];
        for (uint256 i; i < holders.length; ++i) {
            vm.prank(holders[i]);
            adapter.collectFees(holders[i], id, holders[i]);
        }
        (,,,,,,, uint256 left0, uint256 left1) = adapter.positions(lpId);
        uint256 paid0 = weth.balanceOf(ALICE) + (weth.balanceOf(CAROL) - 1_000e18) + weth.balanceOf(DAO);
        assertEq(paid0, 1e18 - left0, "paid what left the position");
        assertApproxEqAbs(paid0, 1e18, 10, "only rounding stays behind");
        assertApproxEqAbs(100e6 - left1, 100e6, 10, "only rounding stays behind");
    }

    /// @dev A seize never pokes, so the gas a liquidator sets can't steer it
    function test_liquidation_neverPokes() public {
        _setEthPrice(1600e8);
        adapter.setPokeBurnsGas(true);
        assertGt(_liquidate(address(usdc), type(uint256).max), 0);
        _assertBalancesSumToSupply();
    }
}
