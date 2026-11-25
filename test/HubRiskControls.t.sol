// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCore} from "../src/interfaces/ISenzuCore.sol";
import {ISenzuRiskConfig} from "../src/interfaces/ISenzuRiskConfig.sol";
import {ACTION_BORROW, ACTION_OPEN, ACTION_SUPPLY, lenderId} from "../src/libraries/Types.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ISenzuBorrowable} from "src/interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";

/// @notice Pauses, what keeps working when the oracle is down, and parameters that only move in borrowers' favor
contract HubRiskControlsTest is HubFixture {
    address constant GUARDIAN = address(0x6A6D);

    function _pause(bytes32 action) internal {
        vm.prank(GUARDIAN);
        riskConfig.setPaused(address(adapter), action, true);
    }

    /*  ================================================
                             Pauses
        ================================================  */

    function test_pause_onlyGuardianOrAdmin() public {
        vm.prank(ALICE);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__NotGuardian.selector);
        riskConfig.setPaused(address(adapter), ACTION_BORROW, true);
    }

    function test_pause_onlyTheThreeActions() public {
        vm.prank(GUARDIAN);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__InvalidAction.selector);
        riskConfig.setPaused(address(adapter), keccak256("SENZU_REPAY"), true);
    }

    function test_pause_openBlocksNewPositionsNotAddingCollateral() public {
        _pause(ACTION_OPEN);
        bytes memory data = abi.encode(address(weth), address(usdc), uint160(1), uint160(2), uint128(1));
        vm.expectRevert(abi.encodeWithSelector(ISenzuCore.SenzuCore__Paused.selector, ACTION_OPEN));
        collateral.open(ALICE, address(this), data);

        // Adding collateral to an existing position only makes it safer
        adapter.setNextIncrease(1e12);
        vm.prank(ALICE);
        collateral.increaseLiquidity(ALICE, id, ALICE, "");
    }

    function test_pause_borrowBlocksBorrowNotRepayOrLiquidation() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.8e18));
        _pause(ACTION_BORROW);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCore.SenzuCore__Paused.selector, ACTION_BORROW));
        collateral.borrow(ALICE, id, address(usdc), 100e6, ALICE);

        // Liquidation still works (part of the debt, so there is some left to repay)
        ethFeed.set(1600e8, block.timestamp);
        usdc.mint(CAROL, 100_000e6);
        vm.startPrank(CAROL);
        usdc.approve(address(borrowable), type(uint256).max);
        lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), 100e6, CAROL);
        vm.stopPrank();

        // Repay still works
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
    }

    /// @dev The key is computed from what the admin names, on a DEX the factory added
    function test_setPairEnabled_keysByDexAndTokens() public {
        vm.expectRevert(abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__UnknownDex.selector, address(0xD3C)));
        riskConfig.setPairEnabled(address(0xD3C), address(weth), address(usdc), true);

        vm.expectEmit(address(riskConfig));
        emit ISenzuRiskConfig.PairEnabledSet(address(adapter), pairKey, address(weth), address(usdc), false);
        riskConfig.setPairEnabled(address(adapter), address(weth), address(usdc), false);
        assertFalse(riskConfig.pairEnabled(pairKey));
    }

    /// @dev A disabled pair or token backs no new debt on an existing position; repaying still works (audit lead
    ///      2026-10-15: only open and reserve checked the listing)
    function test_disabledListing_blocksNewBorrowsNotRepay() public {
        uint256 half = _usdcFor(0.4e18);
        _borrow(ALICE, address(usdc), half);

        riskConfig.setPairEnabled(address(adapter), address(weth), address(usdc), false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__PairNotEnabled.selector, pairKey));
        collateral.borrow(ALICE, id, address(usdc), 1e6, ALICE);

        riskConfig.setPairEnabled(address(adapter), address(weth), address(usdc), true);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.15e18, 1.05e18, false);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__CollateralNotEnabled.selector, address(weth))
        );
        collateral.borrow(ALICE, id, address(usdc), 1e6, ALICE);

        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        vm.stopPrank();
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0);
    }

    function test_pause_supplyBlocksSupplyNotWithdraw() public {
        _pause(ACTION_SUPPLY);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCore.SenzuCore__Paused.selector, ACTION_SUPPLY));
        borrowable.supply(address(usdc), 1e6, BOB);

        uint256 shares = borrowable.balanceOf(BOB, lenderId(address(usdc))) / 2;
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares, BOB, BOB);
    }

    /*  ================================================
                          Oracle down
        ================================================  */

    /// @notice With stale feeds, nothing that returns funds to users may depend on prices
    function test_oracleDown_exitsStillWork() public {
        _borrow(ALICE, address(usdc), 1_000e6);
        vm.warp(block.timestamp + 2 days); // both feeds are past their 1 day heartbeat

        // Lenders can withdraw
        uint256 shares = borrowable.balanceOf(BOB, lenderId(address(usdc))) / 2;
        vm.prank(BOB);
        borrowable.withdraw(address(usdc), shares, BOB, BOB);

        // Borrowers can repay (interest accrued, so Alice needs a little more than she borrowed)
        usdc.mint(ALICE, 10e6);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);

        // With no debt, liquidity can be redeemed
        collateral.redeem(ALICE, id, L / 2, ALICE, "");

        // Borrowing needs prices, so it's refused
        vm.expectRevert();
        collateral.borrow(ALICE, id, address(usdc), 100e6, ALICE);
        vm.stopPrank();
    }

    /// @notice Adding collateral never needs a price (no caps to book it against), so an indebted position can add
    ///         margin while the feeds are stale, and anyone can deposit a position without debt
    function test_oracleDown_addingCollateralStillWorks() public {
        _borrow(ALICE, address(usdc), 1_000e6);
        vm.warp(block.timestamp + 2 days); // both feeds are past their 1 day heartbeat

        adapter.setNextIncrease(L / 10);
        vm.prank(ALICE);
        collateral.increaseLiquidity(ALICE, id, ALICE, "");
        assertEq(collateral.balanceOf(ALICE, id), L + L / 10);

        _open(BOB, L);
    }

    /*  ================================================
                    Only in borrowers' favor
        ================================================  */

    function test_sigma_canOnlyGoDown() public {
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.1e18, 1.05e18, true); // lower: fine
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.11e18, 1.05e18, true);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.1e18, 1.05e18, false); // same σ, collateral off for new positions: fine
    }

    function test_sigma_raiseCouldHaveLiquidated() public {
        // An admin can't push an existing borrower toward liquidation: the σ raise is rejected
        _borrow(ALICE, address(usdc), _usdcFor(0.5e18));
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__OnlyInBorrowersFavor.selector);
        riskConfig.setTokenRisk(address(adapter), address(weth), 1.5e18, 1.05e18, true);
        assertFalse(collateral.health(ALICE, id).minSurplusUsdWad < 0);
    }
}
