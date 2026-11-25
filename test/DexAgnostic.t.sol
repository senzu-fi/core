// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../src/core/SenzuBorrowable.sol";
import {SenzuCollateral} from "../src/core/SenzuCollateral.sol";
import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuFactory} from "../src/interfaces/ISenzuFactory.sol";
import {HealthMath} from "../src/libraries/HealthMath.sol";
import {HealthResult} from "../src/libraries/Types.sol";
import {SenzuLens} from "../src/periphery/SenzuLens.sol";
import {MockBinAdapter} from "./mocks/MockBinAdapter.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";

/**
 *  @dev The core knows nothing of an exchange: what a caller passes for the adapter reaches it unread, and a position
 *       is worth what its adapter says its units hold at each price. The second set here runs on bins (a constant-sum
 *       curve at a fixed price, as Liquidity Book), which have no range to read
 */
contract DexAgnosticTest is HubFixture {
    SenzuCollateral binCollateral;
    SenzuBorrowable binBorrowable;
    MockBinAdapter bins;
    uint160 binPrice;
    uint256 binId;

    function setUp() public override {
        super.setUp();
        ISenzuFactory.Deployment memory d =
            factory.deploy("Bins", address(new MockBinAdapter(factory.collateralAddress("Bins"))));
        binCollateral = SenzuCollateral(d.collateral);
        binBorrowable = SenzuBorrowable(d.borrowable);
        bins = MockBinAdapter(d.adapter);

        riskConfig.setTokenRisk(address(bins), address(weth), 1.15e18, 1.05e18, true);
        riskConfig.setLiquid(address(bins), address(weth));
        riskConfig.setTokenRisk(address(bins), address(usdc), 1.02e18, 1.05e18, true);
        riskConfig.setLiquid(address(bins), address(usdc));
        riskConfig.setPairEnabled(address(bins), address(weth), address(usdc), true);
        // Liquidations here check the bin valuation, not the protocol's fee (LiquidationFee.t.sol covers it)
        riskConfig.setLiquidationFee(address(bins), 0);

        binBorrowable.createMarket(address(usdc), 0.1e18);
        vm.startPrank(BOB);
        usdc.approve(address(binBorrowable), type(uint256).max);
        binBorrowable.supply(address(usdc), 100_000e6, BOB);
        vm.stopPrank();

        // Alice's bin at $2000: 1 WETH and 2000 USDC, worth 4000 USDC there
        binPrice = HealthMath.sqrtPriceX96FromUsd(2000e18, 1e18, 18, 6);
        weth.mint(address(bins), 1e18);
        usdc.mint(address(bins), 2000e6);
        vm.prank(ALICE);
        (binId,,,,,) = binCollateral.open(ALICE, ALICE, abi.encode(address(weth), address(usdc), binPrice));
    }

    /*  ================================================
                      Data for the adapter
        ================================================  */

    function test_increaseLiquidity_passesTheCallersDataToTheAdapter() public {
        adapter.setNextIncrease(L / 10);
        vm.prank(ALICE);
        collateral.increaseLiquidity(ALICE, id, ALICE, hex"c0ffee");
        assertEq(adapter.lastIncreaseData(), hex"c0ffee");
    }

    function test_redeem_passesTheCallersDataToTheAdapter() public {
        vm.prank(ALICE);
        collateral.redeem(ALICE, id, L / 10, ALICE, hex"decaf0");
        assertEq(adapter.lastDecreaseData(), hex"decaf0");
        assertEq(collateral.balanceOf(ALICE, id), L - L / 10);
    }

    /*  ================================================
                    A curve that isn't a range
        ================================================  */

    /// @notice The worst corner is ETH down: arbitrage leaves the bin all WETH, 2 WETH at $2000/1.15. A range of the
    ///         same value would be worth more there (its WETH grows only as √price falls)
    function test_health_valuesWhatTheAdapterReports() public view {
        HealthResult memory h = binCollateral.health(ALICE, binId);
        // The bin's units round its WETH down: one USDC wei under
        assertApproxEqAbs(h.collateralUsdWad, 4000e18, 1e12, "at $2000 the bin is worth its 4000 USDC");
        assertApproxEqRel(uint256(h.minSurplusUsdWad), uint256(4000e36) / 1.15e18, 1e9, "2 WETH at $2000/1.15");
    }

    /// @notice Borrowing stops at the bin's own worst corner: 2 WETH at $2000/1.15 against the debt at USDC·1.02 times
    ///         the penalty, about $3247.7
    function test_borrow_stopsAtTheCurvesWorstCorner() public {
        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        binCollateral.borrow(ALICE, binId, address(usdc), 3250e6, ALICE);

        vm.prank(ALICE);
        binCollateral.borrow(ALICE, binId, address(usdc), 3245e6, ALICE);
        assertFalse(binCollateral.health(ALICE, binId).minSurplusUsdWad < 0);
    }

    /// @notice ETH falls 5%, the bin's worst corner goes short; a liquidator seizes units and redeems them with no data
    function test_liquidation_seizesAndTheSeizedUnitsRedeemWithEmptyData() public {
        vm.prank(ALICE);
        binCollateral.borrow(ALICE, binId, address(usdc), 3200e6, ALICE);
        ethFeed.set(1900e8, block.timestamp);
        assertTrue(binCollateral.health(ALICE, binId).minSurplusUsdWad < 0);

        usdc.mint(CAROL, 1000e6);
        vm.startPrank(CAROL);
        usdc.approve(address(binBorrowable), type(uint256).max);
        (uint256 seized,) = lockLiquidator().liquidate(binCollateral, ALICE, binId, address(usdc), 1000e6, CAROL);
        assertGt(seized, 0);
        (uint256 out0, uint256 out1) = binCollateral.redeem(CAROL, binId, seized, CAROL, "");
        vm.stopPrank();

        assertGt(out0 + out1, 0);
        assertEq(weth.balanceOf(CAROL), out0);
        assertEq(binCollateral.balanceOf(CAROL, binId), 0);
        assertEq(binCollateral.totalSupply(binId), bins.units(binId), "units stay the adapter's");
    }

    /// @notice The lens values a position the core's way, without a range: its range fields stay empty
    function test_lens_matchesTheCoreWithoutARange() public {
        vm.prank(ALICE);
        binCollateral.borrow(ALICE, binId, address(usdc), 3000e6, ALICE);
        SenzuLens lens = new SenzuLens(address(binCollateral));
        SenzuLens.PositionView memory v = lens.getPosition(ALICE, binId);
        HealthResult memory h = binCollateral.health(ALICE, binId);

        assertEq(v.collateralUsdWad, h.collateralUsdWad);
        assertEq(v.healthWad, h.healthWad);
        assertApproxEqAbs(v.amount1, 4000e6, 1, "all USDC at the oracle's price");
        assertEq(v.sqrtPaX96, 0);
        assertEq(v.liquidity, 0);
        // 2 WETH at p/1.15 against 3000 USDC · 1.02 · 1.05: p = $1847.475. ETH going up only leaves it more USDC
        assertApproxEqRel(v.liquidation.lowerWad, 1847.475e18, 1e13);
        assertEq(v.liquidation.upperWad, 0);
    }
}
