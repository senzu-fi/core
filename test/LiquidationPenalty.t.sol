// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../src/interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "../src/interfaces/ISenzuLockCallback.sol";
import {ISenzuPreviews} from "../src/interfaces/ISenzuPreviews.sol";
import {ISenzuRiskConfig} from "../src/interfaces/ISenzuRiskConfig.sol";
import {HealthResult} from "../src/libraries/Types.sol";
import {SenzuPreviews} from "../src/periphery/SenzuPreviews.sol";
import {MockAggregator, MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev In one lock, repays a position's debt in `outside` in full, then liquidates its `pair` debt
contract RepayThenLiquidate is ISenzuLockCallback {
    ISenzuCollateral immutable collateral;
    ISenzuBorrowable immutable borrowable;

    constructor(ISenzuCollateral collateral_, ISenzuBorrowable borrowable_) {
        (collateral, borrowable) = (collateral_, borrowable_);
    }

    function run(address borrower, uint256 id, MockERC20 outside, MockERC20 pair, uint256 amount) external {
        outside.approve(address(borrowable), type(uint256).max);
        pair.approve(address(borrowable), type(uint256).max);
        collateral.lock(abi.encode(borrower, id, outside, pair, amount));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        (address borrower, uint256 id, address outside, address pair, uint256 amount) =
            abi.decode(data, (address, uint256, address, address, uint256));
        borrowable.repay(borrower, id, outside, type(uint256).max);
        (, uint256 repaid, uint256 fee) = collateral.liquidate(borrower, id, pair, amount, address(this));
        collateral.settle(pair, repaid + fee);
        return "";
    }
}

/// @notice The liquidation penalty is set per token: a position pays the highest of its pair's
///         two tokens and its debts outside the pair in its health check; a liquidation pays the pair's, or the
///         repaid asset's own when higher, all of it to the liquidator
contract LiquidationPenaltyTest is HubFixture {
    uint64 constant DAI_PENALTY = 1.1e18;

    MockERC20 dai; // a debt outside the WETH/USDC pair, with a higher penalty than either pair token
    SenzuPreviews lens;

    function setUp() public override {
        super.setUp();
        // Penalty and seizure math without the protocol's liquidation fee (LiquidationFee.t.sol covers the fee)
        riskConfig.setLiquidationFee(address(adapter), 0);
        dai = new MockERC20("DAI", 18);
        oracle.addFeed(address(dai), address(new MockAggregator(8, 1e8)), 1 days);
        borrowable.createMarket(address(dai), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(dai), 1.02e18, DAI_PENALTY, false);
        riskConfig.setLiquid(address(adapter), address(dai));

        dai.mint(BOB, 1_000_000e18);
        vm.startPrank(BOB);
        dai.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(dai), 1_000_000e18, BOB);
        vm.stopPrank();

        lens = new SenzuPreviews(address(collateral));
    }

    /*  ================================================
                           Setting it
        ================================================  */

    function test_penalty_staysBetween2And25Percent() public {
        address token = address(0x70CE);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__InvalidPenalty.selector);
        riskConfig.setTokenRisk(address(adapter), token, 1.1e18, 1.0199e18, true);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__InvalidPenalty.selector);
        riskConfig.setTokenRisk(address(adapter), token, 1.1e18, 1.2501e18, true);

        riskConfig.setTokenRisk(address(adapter), token, 1.1e18, 1.25e18, true);
        riskConfig.setTokenRisk(address(adapter), token, 1.1e18, 1.02e18, true);
        assertEq(riskConfig.tokenRisk(address(adapter), token).penaltyWad, 1.02e18);
    }

    /// @dev Once a token is listed, neither its σ nor its penalty can rise, together or alone
    function test_penalty_canOnlyGoDown() public {
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.04e18, true); // lower: fine
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.04e18, false); // same: fine

        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.0401e18, true);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.16e18, 1.03e18, true); // σ up, penalty down
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.1e18, 1.05e18, true); // σ down, penalty up

        assertEq(riskConfig.tokenRisk(address(adapter), address(weth)).sigmaWad, 1.15e18);
        assertEq(riskConfig.tokenRisk(address(adapter), address(weth)).penaltyWad, 1.04e18);
    }

    /// @dev Raising the penalty would make a healthy position liquidatable: refused
    function test_penalty_raiseCouldHaveLiquidated() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.85e18));
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(usdc), 1.02e18, 1.25e18, true);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
    }

    /*  ================================================
                       Which one applies
        ================================================  */

    /// @dev A pair pays the higher of its two tokens' penalties: lowering the other token changes nothing
    function test_pairPaysItsHigherTokensPenalty() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        uint256 before = collateral.health(ALICE, id).healthWad;

        riskConfig.setTokenRisk(address(adapter), address(usdc), 1.02e18, 1.02e18, true);
        assertEq(collateral.health(ALICE, id).healthWad, before, "WETH's 1.05 still applies");
        assertEq(lens.getPair(address(weth), address(usdc)).penaltyWad, 1.05e18);
        assertEq(lens.getPosition(ALICE, id).penaltyWad, 1.05e18);

        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.03e18, true);
        assertApproxEqRel(collateral.health(ALICE, id).healthWad, before * 105 / 103, 1e12, "now WETH's 1.03");
        assertEq(lens.getPair(address(weth), address(usdc)).penaltyWad, 1.03e18);
        assertEq(lens.getPosition(ALICE, id).penaltyWad, 1.03e18);
    }

    /// @dev A debt outside the pair with a higher penalty raises the position's, until it's repaid
    function test_outsidePairDebtRaisesThePenaltyUntilRepaid() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        uint256 before = collateral.health(ALICE, id).healthWad;

        _borrow(ALICE, address(dai), 1e18); // $1 against ~$4.4k of USDC: the health moves by the penalty alone
        assertApproxEqRel(collateral.health(ALICE, id).healthWad, before * 105 / 110, 0.001e18);
        assertEq(lens.getPosition(ALICE, id).penaltyWad, DAI_PENALTY);

        dai.mint(ALICE, 1e18);
        vm.startPrank(ALICE);
        dai.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(dai), type(uint256).max);
        vm.stopPrank();
        assertEq(collateral.health(ALICE, id).healthWad, before, "back to the pair's");
        assertEq(lens.getPosition(ALICE, id).penaltyWad, 1.05e18);
    }

    /// @dev The lens's maximum borrow of an outside asset counts that asset's higher penalty: it passes, and 1% more
    ///      doesn't
    function test_lensMaxBorrowCountsTheBorrowedAssetsPenalty() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.3e18));
        uint256 max = lens.maxBorrow(ALICE, id, address(dai));
        assertGt(max, 0);

        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.borrow(ALICE, id, address(dai), max * 101 / 100, ALICE);

        _borrow(ALICE, address(dai), max);
        assertEq(lens.getPosition(ALICE, id).penaltyWad, DAI_PENALTY);
    }

    /*  ================================================
                          Liquidation
        ================================================  */

    /// @dev The health check counts the position's highest penalty, but a liquidation seizes at the pair's, or at
    ///      the repaid asset's own when higher: repaying the USDC pays the pair's 1.05, repaying the DAI its 1.10
    function test_liquidationSeizesAtTheRepaidDebtsPenalty() public {
        _borrow(ALICE, address(dai), 1e18);
        _borrow(ALICE, address(usdc), _usdcFor(0.78e18));
        ethFeed.set(1600e8, block.timestamp);
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        HealthResult memory h = collateral.health(ALICE, id);
        assertGt(h.collateralUsdWad, h.debtUsdWad * 110 / 100, "the position bears the whole 1.10");

        uint256 snapshot = vm.snapshotState();
        (uint256 seized, uint256 repaid) = _liquidate(usdc, 100e6);
        assertEq(repaid, 100e6);
        assertApproxEqRel(seized * h.collateralUsdWad / L, repaid * 1e12 * 105 / 100, 1e12, "the pair's 1.05");
        assertEq(collateral.balanceOf(DAO, id), 0, "nothing to protocolReserves");

        vm.revertToState(snapshot);
        (seized, repaid) = _liquidate(dai, 1e18);
        assertEq(repaid, 1e18);
        assertApproxEqRel(seized * h.collateralUsdWad / L, repaid * 110 / 100, 1e12, "DAI's own 1.10");
    }

    /// @dev A token outside the pair at a penalty up to 1.25 seizes at its own when repaid, shrunk to the
    ///      position's collateral / debt when that's lower; the USDC repaid at the same state pays the pair's 1.05
    function test_repaidDebtsPenaltyShrinksToCollateralOverDebt() public {
        MockERC20 x = _listOutside(1.25e18);
        _borrow(ALICE, address(usdc), _usdcFor(0.3e18));
        _borrow(ALICE, address(x), lens.maxBorrow(ALICE, id, address(x)) * 9 / 10);
        int256 price = 2000e8;
        uint256 ratio = type(uint256).max;
        while (ratio >= 1.2e18) {
            price -= 5e8;
            ethFeed.set(price, block.timestamp);
            HealthResult memory h = collateral.health(ALICE, id);
            ratio = h.collateralUsdWad * 1e18 / h.debtUsdWad;
        }
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        assertGt(ratio, 1.05e18, "between the pair's and the token's");
        uint256 unitUsd = collateral.health(ALICE, id).collateralUsdWad / collateral.balanceOf(ALICE, id);

        uint256 snapshot = vm.snapshotState();
        (uint256 seized, uint256 repaid) = _liquidate(x, 100e18);
        assertApproxEqAbs(seized * unitUsd, repaid * ratio / 1e18, unitUsd + 1e12, "x at collateral / debt");

        vm.revertToState(snapshot);
        (seized, repaid) = _liquidate(usdc, 100e6);
        assertApproxEqAbs(seized * unitUsd, repaid * 1e12 * 105 / 100, unitUsd + 1e12, "USDC at the pair's 1.05");
    }

    /// @dev Repaying the debt outside the pair inside a lock drops the position's penalty to the pair's before the
    ///      liquidation reads it: a position liquidatable only because of that debt no longer is
    function test_inLock_repayingTheOutsideDebtFirstLowersThePenalty() public {
        MockERC20 x = _listOutside(1.25e18);
        _borrow(ALICE, address(usdc), _usdcFor(0.6e18));
        _borrow(ALICE, address(x), 10e18);

        // The highest price it's liquidatable at with the outside debt, and whether it is without it
        int256 price = 2000e8;
        while (collateral.health(ALICE, id).minSurplusUsdWad >= 0) {
            price -= 5e8;
            ethFeed.set(price, block.timestamp);
        }
        uint256 snapshot = vm.snapshotState();
        x.mint(ALICE, 20e18);
        vm.startPrank(ALICE);
        x.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(x), type(uint256).max);
        vm.stopPrank();
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0, "healthy at the pair's penalty");
        vm.revertToState(snapshot);

        RepayThenLiquidate liquidator = new RepayThenLiquidate(collateral, borrowable);
        x.mint(address(liquidator), 20e18);
        usdc.mint(address(liquidator), 100e6);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLiquidatable.selector);
        liquidator.run(ALICE, id, x, usdc, 100e6);
    }

    /// @dev Either debt first, any amount, then the other: each liquidation seizes at its own debt's penalty (shrunk
    ///      to collateral / debt), never more, and a position covering 1.02 × its debt keeps its ratio
    function testFuzz_eachLiquidationSeizesAtItsDebtsPenalty(
        uint64 wethPenalty,
        uint64 usdcPenalty,
        uint64 outsidePenalty,
        uint256 usdcFraction,
        uint256 outsideFraction,
        uint256 drop,
        uint256 amount,
        bool outsideFirst
    ) public {
        wethPenalty = uint64(bound(wethPenalty, 1.02e18, 1.05e18));
        usdcPenalty = uint64(bound(usdcPenalty, 1.02e18, 1.05e18));
        outsidePenalty = uint64(bound(outsidePenalty, 1.02e18, 1.25e18));
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, wethPenalty, true);
        riskConfig.setTokenRisk(address(adapter), address(usdc), 1.02e18, usdcPenalty, true);
        MockERC20 x = _listOutside(outsidePenalty);
        uint256 pairPenalty = _max(wethPenalty, usdcPenalty);

        _borrow(ALICE, address(usdc), _usdcFor(bound(usdcFraction, 0.05e18, 0.6e18)));
        uint256 xDebt = lens.maxBorrow(ALICE, id, address(x)) * bound(outsideFraction, 0.01e18, 0.99e18) / 1e18;
        _borrow(ALICE, address(x), xDebt == 0 ? 1 : xDebt);
        assertEq(lens.getPosition(ALICE, id).penaltyWad, _max(pairPenalty, outsidePenalty));
        assertEq(lens.getPosition(ALICE, id).healthWad, collateral.health(ALICE, id).healthWad);

        int256 price = 2000e8;
        while (collateral.health(ALICE, id).minSurplusUsdWad >= 0) {
            price -= 5e8;
            ethFeed.set(price, block.timestamp);
        }
        ethFeed.set(price * int256(1e18 - bound(drop, 0, 0.5e18)) / 1e18, block.timestamp);

        (MockERC20 first, MockERC20 second) = outsideFirst ? (x, usdc) : (usdc, x);
        uint256 firstDebt = borrowable.debtOf(ALICE, id, address(first));
        _checkLiquidation(
            first, bound(amount, 1, firstDebt), first == x ? _max(pairPenalty, outsidePenalty) : pairPenalty
        );
        if (
            collateral.balanceOf(ALICE, id) != 0 && borrowable.debtOf(ALICE, id, address(second)) != 0
                && collateral.health(ALICE, id).minSurplusUsdWad < 0
        ) {
            _checkLiquidation(
                second,
                borrowable.debtOf(ALICE, id, address(second)),
                second == x ? _max(pairPenalty, outsidePenalty) : pairPenalty
            );
        }
    }

    /// @dev The previews count a borrow outside the pair at its own penalty: its maximum leverage passes previewOpen
    ///      and 0.1% more doesn't, and lowering the token's penalty raises it
    function test_previewsCountAnOutsideBorrowsPenalty() public {
        MockERC20 x = _listOutside(1.25e18);
        uint256 max = lens.maxLeverage(
            address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(x)
        );
        assertGt(max, 1e18);
        // Borrow (λ − 1) · $2,000 of x on 1 WETH
        assertTrue(_previewOutside(x, (max * 999 / 1000 - 1e18) * 2_000), "just below max: allowed");
        assertFalse(_previewOutside(x, (max * 1001 / 1000 - 1e18) * 2_000), "just above max: not allowed");

        riskConfig.setTokenRisk(address(adapter), address(x), 1.02e18, 1.05e18, false);
        riskConfig.setLiquid(address(adapter), address(x));
        assertGt(
            lens.maxLeverage(
                address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, address(x)
            ),
            max
        );
    }

    function _previewOutside(MockERC20 x, uint256 amount) private view returns (bool) {
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (address(x), amount);
        return lens.previewOpen(
            ISenzuPreviews.OpenParams({
                token0: address(weth),
                token1: address(usdc),
                sqrtPaX96: TickMath.MIN_SQRT_PRICE,
                sqrtPbX96: TickMath.MAX_SQRT_PRICE,
                deposit0: 1e18,
                deposit1: 0,
                borrowAssets: assets,
                borrowAmounts: amounts,
                swap: true
            })
        )
        .allowed;
    }

    /// @dev Liquidates `amount` of `asset` and checks the seize against `penaltyWad` as the position bears it
    function _checkLiquidation(MockERC20 asset, uint256 amount, uint256 penaltyWad) private {
        HealthResult memory before = collateral.health(ALICE, id);
        uint256 balance = collateral.balanceOf(ALICE, id);
        uint256 ratio = before.collateralUsdWad * 1e18 / before.debtUsdWad;
        uint256 bearable = ratio >= penaltyWad ? penaltyWad : _max(ratio, 1.02e18);

        (uint256 seized, uint256 repaid) = _liquidate(asset, amount);
        uint256 repaidUsd = asset == usdc ? repaid * 1e12 : repaid;
        uint256 takenUsd = seized * before.collateralUsdWad / balance;
        assertLe(takenUsd, repaidUsd * penaltyWad / 1e18 + 1e12, "more than repaid x the debt's penalty");
        if (seized < balance) {
            assertApproxEqAbs(
                takenUsd,
                repaidUsd * bearable / 1e18,
                before.collateralUsdWad / balance + 1e12,
                "at the bearable penalty"
            );
        }
        if (ratio >= 1.02e18) {
            HealthResult memory after_ = collateral.health(ALICE, id);
            if (after_.debtUsdWad > 1e12) {
                assertGe(
                    (after_.collateralUsdWad + 2e12) * before.debtUsdWad,
                    before.collateralUsdWad * (after_.debtUsdWad - 1e12),
                    "a covered ratio dropped"
                );
            }
        }
    }

    /// @dev A $1 token outside the WETH/USDC pair, listed at `penaltyWad`, with Bob's supply to borrow
    function _listOutside(uint64 penaltyWad) private returns (MockERC20 x) {
        x = new MockERC20("X", 18);
        oracle.addFeed(address(x), address(new MockAggregator(8, 1e8)), 1 days);
        borrowable.createMarket(address(x), 0.1e18);
        riskConfig.setTokenRisk(address(adapter), address(x), 1.02e18, penaltyWad, false);
        riskConfig.setLiquid(address(adapter), address(x));
        x.mint(BOB, 10_000_000e18);
        vm.startPrank(BOB);
        x.approve(address(borrowable), type(uint256).max);
        borrowable.supply(address(x), 10_000_000e18, BOB);
        vm.stopPrank();
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _liquidate(MockERC20 asset, uint256 amount) private returns (uint256 seized, uint256 repaid) {
        asset.mint(CAROL, amount);
        vm.startPrank(CAROL);
        asset.approve(address(borrowable), type(uint256).max);
        uint256 held = collateral.balanceOf(CAROL, id);
        (seized, repaid) = lockLiquidator().liquidate(collateral, ALICE, id, address(asset), amount, CAROL);
        vm.stopPrank();
        assertEq(collateral.balanceOf(CAROL, id), held + seized);
    }
}
