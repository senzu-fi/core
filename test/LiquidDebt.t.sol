// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {MockAggregator, MockERC20, MockStock} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";
import {ISenzuPreviews} from "src/interfaces/ISenzuPreviews.sol";
import {ISenzuRiskConfig} from "src/interfaces/ISenzuRiskConfig.sol";
import {SenzuPreviews} from "src/periphery/SenzuPreviews.sol";

/// @notice A debt is one of the position's pair tokens or a token flagged `liquid`: a
///         liquidator must buy the debt token to repay it, so a thin token is owed only in its own pair
contract LiquidDebtTest is HubFixture {
    MockERC20 thin;
    ISenzuPreviews lens;

    function setUp() public override {
        super.setUp();
        lens = new SenzuPreviews(address(collateral));
        thin = new MockERC20("THIN", 18);
        oracle.addFeed(address(thin), address(new MockAggregator(8, 10e8)), 1 days);
        borrowable.createMarket(address(thin), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(thin), 1.3e18, 1.05e18, true);

        thin.mint(BOB, 10_000e18);
        vm.startPrank(BOB);
        thin.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(thin), 10_000e18, BOB);
        vm.stopPrank();
    }

    function test_illiquidDebtOutsideThePair_isRefused() public {
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__IlliquidDebtOutsideItsPair.selector, address(thin))
        );
        collateral.borrow(ALICE, id, address(thin), 10e18, ALICE);
    }

    function test_liquidDebtOutsideThePair_isAllowed() public {
        riskConfig.setLiquid(address(adapter), address(thin));
        _borrow(ALICE, address(thin), 10e18);
        assertEq(borrowable.debtOf(ALICE, id, address(thin)), 10e18);
    }

    /// @dev In its own pair a token needs no flag: the position holds it, and its pool is where it trades
    function test_pairTokenNeedsNoFlag() public {
        riskConfig.setPairEnabled(address(adapter), address(thin), address(usdc), true);
        bytes memory data =
            abi.encode(address(thin), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, uint128(1e15));
        vm.startPrank(CAROL);
        (uint256 thinId,,,,,) = collateral.open(CAROL, CAROL, data);
        collateral.borrow(CAROL, thinId, address(thin), 10e18, CAROL);
        vm.stopPrank();
        assertFalse(riskConfig.tokenRisk(address(adapter), address(thin)).liquid);
        assertEq(borrowable.debtOf(CAROL, thinId, address(thin)), 10e18);
    }

    /// @dev Set-only: no way to clear it, and setting σ or the penalty again keeps it
    function test_setLiquid_isKeptBySetTokenRisk() public {
        vm.expectEmit(address(riskConfig));
        emit ISenzuRiskConfig.LiquidSet(address(adapter), address(thin));
        riskConfig.setLiquid(address(adapter), address(thin));
        riskConfig.setTokenRisk(address(adapter), address(thin), 1.2e18, 1.04e18, false);
        assertTrue(riskConfig.tokenRisk(address(adapter), address(thin)).liquid);
    }

    function test_setLiquid_rules() public {
        vm.prank(ALICE);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__NotAdmin.selector);
        riskConfig.setLiquid(address(adapter), address(thin));

        vm.expectRevert(abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__UnknownDex.selector, address(0xD3C)));
        riskConfig.setLiquid(address(0xD3C), address(thin));

        // Only a token with its risk set on that DEX
        MockERC20 unlisted = new MockERC20("NEW", 18);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__CannotBeLiquid.selector, address(unlisted))
        );
        riskConfig.setLiquid(address(adapter), address(unlisted));

        // Only a token with its feed: one listed first and given a pausable feed after must not stay liquid
        MockStock early = new MockStock("EARLY");
        riskConfig.setTokenRisk(address(adapter), address(early), 1.15e18, 1.05e18, true);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__CannotBeLiquid.selector, address(early))
        );
        riskConfig.setLiquid(address(adapter), address(early));

        // Never a stock: its price pauses, and a liquidation of a position owing it outside its pair would wait
        MockStock nvda = new MockStock("NVDA");
        oracle.addPausableFeed(address(nvda), address(new MockAggregator(8, 180e8)), 1 days);
        riskConfig.setTokenRisk(address(adapter), address(nvda), 1.15e18, 1.05e18, true);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__CannotBeLiquid.selector, address(nvda))
        );
        riskConfig.setLiquid(address(adapter), address(nvda));
    }

    /// @dev The previews offer nothing the borrow would refuse
    function test_previews_offerNoIlliquidBorrowOutsideThePair() public {
        assertEq(lens.maxBorrow(ALICE, id, address(thin)), 0);
        assertEq(
            lens.maxLeverage(
                address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(thin)
            ),
            1e18
        );
        assertFalse(lens.previewOpen(_openBorrowing(10e18)).allowed);
        assertTrue(lens.previewOpen(_openBorrowing(0)).allowed, "a zero amount is no debt");

        riskConfig.setLiquid(address(adapter), address(thin));
        assertGt(lens.maxBorrow(ALICE, id, address(thin)), 0);
        assertGt(
            lens.maxLeverage(
                address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(thin)
            ),
            1e18
        );
        assertTrue(lens.previewOpen(_openBorrowing(10e18)).allowed);
    }

    /// @dev A position owes at most two assets: no third to offer
    function test_previews_offerNoThirdDebt() public {
        riskConfig.setLiquid(address(adapter), address(thin));
        _borrow(ALICE, address(usdc), 100e6);
        assertGt(lens.maxBorrow(ALICE, id, address(thin)), 0, "a second debt");
        _borrow(ALICE, address(weth), 0.01e18);
        assertEq(lens.maxBorrow(ALICE, id, address(thin)), 0, "no third");
        assertGt(lens.maxBorrow(ALICE, id, address(usdc)), 0, "more of one it owes");

        ISenzuPreviews.OpenParams memory params = _openBorrowing(10e18);
        params.borrowAssets = new address[](3);
        (params.borrowAssets[0], params.borrowAssets[1], params.borrowAssets[2]) =
        (address(thin), address(usdc), address(weth));
        params.borrowAmounts = new uint256[](3);
        (params.borrowAmounts[0], params.borrowAmounts[1], params.borrowAmounts[2]) = (1e18, 10e6, 0.001e18);
        assertFalse(lens.previewOpen(params).allowed, "three debts");
        params.borrowAmounts[2] = 0;
        assertTrue(lens.previewOpen(params).allowed, "a zero amount is no debt");

        params.borrowAmounts = new uint256[](2);
        vm.expectRevert(ISenzuPreviews.SenzuPreviews__LengthMismatch.selector);
        lens.previewOpen(params);
    }

    function _openBorrowing(uint256 amount) internal view returns (ISenzuPreviews.OpenParams memory params) {
        params.token0 = address(weth) < address(usdc) ? address(weth) : address(usdc);
        params.token1 = address(weth) < address(usdc) ? address(usdc) : address(weth);
        params.sqrtPaX96 = TickMath.MIN_SQRT_PRICE;
        params.sqrtPbX96 = TickMath.MAX_SQRT_PRICE;
        (params.deposit0, params.deposit1) =
            params.token0 == address(weth) ? (uint256(1e18), uint256(2_000e6)) : (uint256(2_000e6), uint256(1e18));
        params.borrowAssets = new address[](1);
        params.borrowAssets[0] = address(thin);
        params.borrowAmounts = new uint256[](1);
        params.borrowAmounts[0] = amount;
        params.swap = true;
    }
}
