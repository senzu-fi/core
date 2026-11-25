// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLens} from "../src/interfaces/ISenzuLens.sol";
import {ISenzuPreviews} from "../src/interfaces/ISenzuPreviews.sol";
import {ISenzuRiskConfig} from "../src/interfaces/ISenzuRiskConfig.sol";
import {Market, lenderId} from "../src/libraries/Types.sol";
import {SenzuPreviews} from "../src/periphery/SenzuPreviews.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @notice Optional opening fee: charged on every borrow, added to the debt, minted to the DAO as lender shares
contract BorrowFeeTest is HubFixture {
    uint256 usdcId;

    function setUp() public override {
        super.setUp();
        usdcId = lenderId(address(usdc));
    }

    function _daoUsdc() internal view returns (uint256) {
        uint256 shares = borrowable.balanceOf(DAO, usdcId) + borrowable.getMarket(address(usdc)).pendingReserveShares;
        return borrowable.convertToAssets(address(usdc), shares);
    }

    function test_defaultIsZero() public {
        assertEq(riskConfig.borrowFeeWad(address(adapter)), 0);
        _borrow(ALICE, address(usdc), 1_000e6);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 1_000e6);
        assertEq(borrowable.balanceOf(DAO, usdcId), 0);
    }

    function test_setBorrowFee_bounds() public {
        riskConfig.setBorrowFee(address(adapter), 0.002e18);
        assertEq(riskConfig.borrowFeeWad(address(adapter)), 0.002e18);

        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__InvalidBorrowFee.selector);
        riskConfig.setBorrowFee(address(adapter), 0.002e18 + 1);

        vm.prank(ALICE);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__NotAdmin.selector);
        riskConfig.setBorrowFee(address(adapter), 0);
    }

    function test_feeIsDebtAndGoesToTheDao() public {
        riskConfig.setBorrowFee(address(adapter), 0.002e18); // 0.20%
        uint256 bobBefore = borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId));
        Market memory before = borrowable.getMarket(address(usdc));

        _borrow(ALICE, address(usdc), 1_000e6);

        // Alice receives 1,000 and owes 1,002
        assertEq(usdc.balanceOf(ALICE), 1_000e6);
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 1_002e6);

        // Cash only drops by what left; supply and borrows both grow by the fee
        Market memory afterBorrow = borrowable.getMarket(address(usdc));
        assertEq(afterBorrow.totalSupplyAssets, before.totalSupplyAssets + 2e6);
        assertEq(afterBorrow.totalBorrowAssets, before.totalBorrowAssets + 1_002e6);

        // The DAO owns the fee as lender shares; Bob isn't diluted
        assertApproxEqAbs(_daoUsdc(), 2e6, 1);
        assertApproxEqAbs(borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId)), bobBefore, 1);
    }

    /// @notice The protocol's shares wait in the market until `mintReserves`: minting them, at any moment, moves no
    ///         lender's assets and no share price, only where the shares are held
    function test_mintReserves_changesNoSharePrice() public {
        riskConfig.setBorrowFee(address(adapter), 0.002e18);
        _borrow(ALICE, address(usdc), 1_000e6);
        vm.warp(block.timestamp + 30 days);
        borrowable.accrueInterest(address(usdc));

        uint256 pending = borrowable.getMarket(address(usdc)).pendingReserveShares;
        assertGt(pending, 0, "fee and reserve shares wait");
        uint256 supply = borrowable.totalSupply(usdcId);
        uint256 bob = borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId));
        uint256 bobMax = borrowable.maxWithdraw(address(usdc), BOB);
        uint256 dao = _daoUsdc();
        uint256 carolShares = _supplyAsCarol(1_000e6);

        vm.prank(CAROL);
        assertEq(borrowable.mintReserves(address(usdc)), pending, "anyone may mint them");

        assertEq(borrowable.getMarket(address(usdc)).pendingReserveShares, 0);
        assertEq(borrowable.balanceOf(DAO, usdcId), pending, "to protocolReserves");
        assertEq(borrowable.totalSupply(usdcId), supply, "the supply already counted them");
        assertEq(borrowable.convertToAssets(address(usdc), borrowable.balanceOf(BOB, usdcId)), bob);
        assertEq(borrowable.maxWithdraw(address(usdc), BOB), bobMax);
        assertEq(_daoUsdc(), dao);
        assertEq(_supplyAsCarol(1_000e6), carolShares, "a new lender gets the same shares");
        assertEq(borrowable.mintReserves(address(usdc)), 0, "nothing left to mint");
    }

    /// @dev Shares a supply by Carol would get now, without keeping it
    function _supplyAsCarol(uint256 assets) internal returns (uint256 shares) {
        uint256 snapshot = vm.snapshotState();
        usdc.mint(CAROL, assets);
        vm.startPrank(CAROL);
        usdc.approve(address(borrowable), assets);
        shares = borrowable.supply(address(usdc), assets, CAROL);
        vm.stopPrank();
        vm.revertToState(snapshot);
    }

    function test_feeCountsInHealth() public {
        // The largest borrow without a fee fails with one: the fee is debt too
        SenzuPreviews lens = new SenzuPreviews(address(collateral));
        uint256 maxNoFee = lens.maxBorrow(ALICE, id, address(usdc));

        riskConfig.setBorrowFee(address(adapter), 0.002e18);
        uint256 maxWithFee = lens.maxBorrow(ALICE, id, address(usdc));
        assertApproxEqRel(maxWithFee, maxNoFee * 1e18 / 1.002e18, 1e14);

        vm.prank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.borrow(ALICE, id, address(usdc), maxWithFee * 1001 / 1000, ALICE);
        _borrow(ALICE, address(usdc), maxWithFee);
    }

    function test_previewIncludesFee() public {
        riskConfig.setBorrowFee(address(adapter), 0.002e18);
        SenzuPreviews lens = new SenzuPreviews(address(collateral));
        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (assets[0], amounts[0]) = (address(usdc), 2_000e6);
        ISenzuPreviews.OpenPreview memory p = lens.previewOpen(
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
        );
        assertEq(p.debtUsdWad, 2_004e18);
        assertApproxEqRel(p.collateralUsdWad, 4_000e18, 1e9, "size counts what was borrowed, not the fee");
    }
}
