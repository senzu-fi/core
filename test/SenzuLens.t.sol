// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLens} from "../src/interfaces/ISenzuLens.sol";
import {ISenzuPreviews} from "../src/interfaces/ISenzuPreviews.sol";
import {HealthMath} from "../src/libraries/HealthMath.sol";
import {MarketLogic} from "../src/libraries/MarketLogic.sol";
import {HealthResult} from "../src/libraries/Types.sol";
import {LiquidityAmounts} from "../src/libraries/uniswap/LiquidityAmounts.sol";
import {SenzuPreviews} from "../src/periphery/SenzuPreviews.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice The lens agrees with the collateral: same health, and its searches land on the real boundaries
contract SenzuLensTest is HubFixture {
    SenzuPreviews lens;

    function setUp() public override {
        super.setUp();
        lens = new SenzuPreviews(address(collateral));
    }

    function _setEth(uint256 priceWad) internal {
        ethFeed.set(int256(priceWad / 1e10), block.timestamp);
    }

    /*  ================================================
                             Tables
        ================================================  */

    function test_markets() public view {
        ISenzuLens.MarketView[] memory markets = lens.getMarkets();
        assertEq(markets.length, 2);
        assertEq(markets[0].asset, address(usdc));
        assertEq(markets[0].decimals, 6);
        assertEq(markets[0].supplyAssets, 1_000_000e6);
        assertEq(markets[0].cash, 1_000_000e6);
        assertEq(markets[0].priceWad, 1e18);
        assertEq(markets[1].priceWad, 2000e18);
    }

    /// @dev With its accrued totals and the borrow shares (which accrual leaves alone), a market view is the market as
    ///      the borrowable books a borrow now: what the app passes the SDK to preview an open exactly
    function test_markets_borrowSharesAsBooked() public {
        vm.prank(ALICE);
        collateral.borrow(ALICE, id, address(usdc), 1_000e6, ALICE);
        vm.warp(block.timestamp + 12 hours); // interest accrues in view, within the feeds' 1-day heartbeat
        ISenzuLens.MarketView memory m = lens.getMarket(address(usdc));
        assertGt(m.borrowAssets, 1_000e6, "accrued");
        assertEq(m.borrowShares, borrowable.getMarket(address(usdc)).totalBorrowShares);
        assertEq(m.borrowAssets, borrowable.debtOf(ALICE, id, address(usdc)), "accrued, as debtOf reads it");

        // Rates as of now: the rate at target adapted over the 12 hours (down, at 0.1% utilization), the curve on it
        (,,, uint256 borrowRate, uint256 supplyRate, uint256 rateAtTarget) = borrowable.marketState(address(usdc));
        assertLt(rateAtTarget, MarketLogic.INITIAL_RATE_AT_TARGET, "adapted down");
        assertEq(m.rateAtTargetAprWad, rateAtTarget * 365 days);
        assertEq(m.borrowAprWad, borrowRate * 365 days);
        assertEq(m.supplyAprWad, supplyRate * 365 days);
    }

    function test_lender() public view {
        ISenzuLens.LenderView[] memory rows = lens.getLender(BOB);
        assertEq(rows.length, 2);
        assertApproxEqAbs(rows[0].assets, 1_000_000e6, 1);
        assertApproxEqRel(rows[0].valueUsdWad, 1_000_000e18, 1e12);
        assertApproxEqRel(rows[1].valueUsdWad, 2_000_000e18, 1e12);
        assertEq(lens.getLender(ALICE).length, 0);
    }

    function test_pair() public view {
        ISenzuLens.PairView memory p = lens.getPair(address(weth), address(usdc));
        assertEq(p.pairKey, pairKey);
        assertTrue(p.enabled);
        assertEq(p.sigma0Wad, 1.15e18);
        assertEq(p.sigma1Wad, 1.02e18);
        assertEq(p.penaltyWad, 1.05e18);
    }

    function test_positionMatchesCollateral() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        _borrow(ALICE, address(weth), 0.5e18);

        ISenzuLens.PositionView memory v = lens.getPosition(ALICE, id);
        HealthResult memory h = collateral.health(ALICE, id);
        assertEq(v.healthWad, h.healthWad);
        assertEq(v.collateralUsdWad, h.collateralUsdWad);
        assertEq(v.debtUsdWad, h.debtUsdWad);
        assertEq(v.marginUsdWad, int256(h.collateralUsdWad) - int256(h.debtUsdWad));
        assertEq(v.debts.length, 2);
        assertEq(v.liquidity, L);
        assertTrue(v.inRange);
        assertGt(v.debts[0].borrowAprWad, 0);
        assertEq(lens.getPositions(ALICE, new uint256[](0)).length, 0);
    }

    /*  ================================================
                       Liquidation prices
        ================================================  */

    function test_liquidationPrice_isTheBoundary() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.6e18));

        ISenzuLens.LiquidationPrices memory liq = lens.getPosition(ALICE, id).liquidation;
        assertEq(liq.token, address(weth), "ETH is the more volatile token");
        assertGt(liq.lowerWad, 0);
        assertLt(liq.lowerWad, 2000e18);
        assertEq(liq.upperWad, 0, "USDC debt against full range: ETH going up only helps");

        _setEth(liq.lowerWad * 10_001 / 10_000);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0, "just above: safe");
        _setEth(liq.lowerWad * 9_999 / 10_000);
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0, "just below: liquidatable");
    }

    function test_liquidationPrice_bothSidesForAnEthDebt() public {
        // Borrowing ETH against a range: ETH going up grows the debt faster than the position
        _borrow(ALICE, address(weth), 1.4e18);
        ISenzuLens.LiquidationPrices memory liq = lens.getPosition(ALICE, id).liquidation;
        assertGt(liq.upperWad, 2000e18);

        _setEth(liq.upperWad * 9_999 / 10_000);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        _setEth(liq.upperWad * 10_001 / 10_000);
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);
    }

    function test_liquidationPrice_noDebt() public view {
        ISenzuLens.LiquidationPrices memory liq = lens.getPosition(ALICE, id).liquidation;
        assertEq(liq.lowerWad, 0);
        assertEq(liq.upperWad, 0);
    }

    /*  ================================================
                           Max borrow
        ================================================  */

    function test_maxBorrow_isTheBoundary() public {
        uint256 max = lens.maxBorrow(ALICE, id, address(usdc));
        assertGt(max, 0);

        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.borrow(ALICE, id, address(usdc), max * 1001 / 1000, ALICE);

        _borrow(ALICE, address(usdc), max);
        assertLt(lens.maxBorrow(ALICE, id, address(usdc)), max / 1e5, "nothing left after borrowing the max");
    }

    function test_maxBorrow_cappedByCash() public {
        // A tiny market: cash is the limit
        uint256 shares = borrowable.balanceOf(BOB, uint256(uint160(address(weth))));
        uint256 keep = borrowable.convertToShares(address(weth), 1e18);
        vm.prank(BOB);
        borrowable.withdraw(address(weth), shares - keep, BOB, BOB);
        assertLe(lens.maxBorrow(ALICE, id, address(weth)), 1e18 + 1);
    }

    /*  ================================================
                     Create position panel
        ================================================  */

    function _preview(uint256 depositWeth, uint256 borrowUsdc, bool swap)
        internal
        view
        returns (ISenzuPreviews.OpenPreview memory)
    {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (address(usdc), borrowUsdc);
        return lens.previewOpen(
            ISenzuPreviews.OpenParams({
                token0: address(weth),
                token1: address(usdc),
                sqrtPaX96: TickMath.MIN_SQRT_PRICE,
                sqrtPbX96: TickMath.MAX_SQRT_PRICE,
                deposit0: depositWeth,
                deposit1: 0,
                borrowAssets: assets,
                borrowAmounts: amounts,
                swap: swap
            })
        );
    }

    function test_previewOpen_leverage() public view {
        // 1 WETH ($2,000) of margin, borrow $2,000 of USDC and swap: 2x
        ISenzuPreviews.OpenPreview memory p = _preview(1e18, 2_000e6, true);
        assertApproxEqRel(p.marginUsdWad, 2_000e18, 1e12);
        assertApproxEqRel(p.collateralUsdWad, 4_000e18, 1e9);
        assertApproxEqRel(p.leverageWad, 2e18, 1e9);
        assertEq(p.debtUsdWad, 2_000e18);
        assertTrue(p.allowed);
        assertGt(p.liquidation.lowerWad, 0);

        // Without a swap only the WETH fits nothing (full range needs both): USDC alone can't pair with it all
        ISenzuPreviews.OpenPreview memory noSwap = _preview(1e18, 2_000e6, false);
        assertLt(noSwap.collateralUsdWad, p.collateralUsdWad);
    }

    function test_maxLeverage_matchesPreview() public view {
        uint256 max = lens.maxLeverage(
            address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(usdc)
        );
        assertGt(max, 1.5e18);
        assertLt(max, 20e18);

        // Borrow (λ − 1) · $2,000 of USDC on 1 WETH
        uint256 below = (max * 999 / 1000 - 1e18) * 2_000e6 / 1e18;
        uint256 above = (max * 1001 / 1000 - 1e18) * 2_000e6 / 1e18;
        assertTrue(_preview(1e18, below, true).allowed, "just below max: allowed");
        assertFalse(_preview(1e18, above, true).allowed, "just above max: not allowed");
    }

    function test_maxLeverage_bothLegsBeatsSingleAsset() public view {
        // Borrowing both pair tokens at the range's ratio hedges the position: more leverage than all-USDC
        uint256 both = lens.maxLeverage(
            address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(0)
        );
        uint256 single = lens.maxLeverage(
            address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(usdc)
        );
        assertGt(both, single);
    }

    /*  ================================================
                          Swap sizing
        ================================================  */

    function _range(uint256 lowUsd, uint256 highUsd) internal pure returns (uint160 a, uint160 b) {
        a = HealthMath.sqrtPriceX96FromUsd(lowUsd, 1e18, 18, 6);
        b = HealthMath.sqrtPriceX96FromUsd(highUsd, 1e18, 18, 6);
    }

    /// @dev After the quoted swap, amount0 : amount1 equals what the range needs at the price
    function _assertFitsRange(uint256 x, uint256 y, uint160 a, uint160 b, uint256 feeWad) internal view {
        ISenzuPreviews.SwapQuote memory q = lens.swapForRange(address(weth), address(usdc), a, b, x, y, 0, feeWad);
        (x, y) = q.zeroForOne ? (x - q.amountIn, y + q.amountOut) : (x + q.amountOut, y - q.amountIn);

        uint160 p = HealthMath.sqrtPriceX96FromUsd(2000e18, 1e18, 18, 6);
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(p, a, b, 1e18);
        assertApproxEqRel(x * a1, y * a0, 1e9, "amounts fit the range ratio");
    }

    function test_swapForRange_sellsTheExcessToken() public view {
        (uint160 a, uint160 b) = _range(1800e18, 2200e18);
        _assertFitsRange(1e18, 0, a, b, 0.003e18); // only WETH: sells WETH
        _assertFitsRange(0, 5_000e6, a, b, 0.003e18); // only USDC: sells USDC
        _assertFitsRange(2e18, 1_000e6, a, b, 0.0005e18);
        _assertFitsRange(0.1e18, 9_000e6, a, b, 0);
    }

    function test_swapForRange_noFeeConservesValue() public view {
        (uint160 a, uint160 b) = _range(1800e18, 2200e18);
        ISenzuPreviews.SwapQuote memory q = lens.swapForRange(address(weth), address(usdc), a, b, 1e18, 0, 0, 0);
        assertTrue(q.zeroForOne);
        assertApproxEqRel(q.amountIn * 2000 / 1e12, q.amountOut, 1e12, "WETH in at $2,000 = USDC out");
    }

    function test_swapForRange_outOfRangeSwapsEverything() public view {
        // Range above the price holds only WETH (token0): all USDC is sold
        (uint160 a, uint160 b) = _range(2200e18, 2500e18);
        ISenzuPreviews.SwapQuote memory q = lens.swapForRange(address(weth), address(usdc), a, b, 1e18, 3_000e6, 0, 0);
        assertFalse(q.zeroForOne);
        assertEq(q.amountIn, 3_000e6);
        assertApproxEqRel(q.amountOut, 1.5e18, 1e12);
    }

    function test_swapForRange_lowPriceEighteenAgainstSixDecimals() public view {
        // 18-dec token0 at $1e-3..$1e-9 against 6-dec USDC ($1), $1,000 USDC into a +-20% range
        uint256 price = 1e15;
        for (uint256 i; i < 7; ++i) {
            uint160 s = HealthMath.sqrtPriceX96FromUsd(price, 1e18, 18, 6);
            uint160 a = HealthMath.sqrtPriceX96FromUsd(price * 8 / 10, 1e18, 18, 6);
            uint160 b = HealthMath.sqrtPriceX96FromUsd(price * 12 / 10, 1e18, 18, 6);
            ISenzuPreviews.SwapQuote memory q =
                lens.swapForRange(address(weth), address(usdc), a, b, 0, 1_000e6, s, 0.003e18);
            assertFalse(q.zeroForOne);
            assertGt(q.amountIn, 400e6);
            assertLt(q.amountIn, 500e6);
            assertGt(q.amountOut, 0);
            // Post-swap token0 value / remaining token1 value matches s(b - s) / (b(s - a))
            uint256 xVal = (q.amountOut * price) / 1e30; // in 6-dec USDC units
            uint256 yRem = 1_000e6 - q.amountIn;
            uint256 expectedRatio = (uint256(s) * (b - s) * 1e18) / (uint256(b) * (s - a));
            assertApproxEqRel((xVal * 1e18) / yRem, expectedRatio, 1e12, "low-price swap fits range");
            price /= 10;
        }
    }
}
