// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../src/interfaces/ISenzuAdapter.sol";
import {ISenzuRiskConfig} from "../src/interfaces/ISenzuRiskConfig.sol";
import {HubFixture} from "./utils/HubFixture.sol";

/// @notice The protocol's cut of the LP fees holders collect: paid at payout to the factory's `protocolReserves`
contract FeeCutTest is HubFixture {
    uint64 constant CUT = 0.02e18;

    /// @dev The smallest amount owed whose net is `net`: undoes a cut rounded down
    function _gross(uint256 net) internal pure returns (uint256) {
        return (net * 1e18 + (1e18 - CUT) - 1) / (1e18 - CUT);
    }

    function test_feeCut_defaultIsZero_capIs5Percent() public {
        (uint64 cutWad, address to) = riskConfig.feeCut(address(adapter));
        assertEq(cutWad, 0);
        assertEq(to, DAO);

        vm.expectEmit(address(riskConfig));
        emit ISenzuRiskConfig.FeeCutSet(address(adapter), 0.05e18);
        riskConfig.setFeeCut(address(adapter), 0.05e18);
        (cutWad,) = riskConfig.feeCut(address(adapter));
        assertEq(cutWad, 0.05e18);

        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__InvalidFeeCut.selector);
        riskConfig.setFeeCut(address(adapter), 0.05e18 + 1);
        vm.expectRevert(abi.encodeWithSelector(ISenzuRiskConfig.SenzuRiskConfig__UnknownDex.selector, address(0xDE)));
        riskConfig.setFeeCut(address(0xDE), CUT);
        vm.prank(ALICE);
        vm.expectRevert(ISenzuRiskConfig.SenzuRiskConfig__NotAdmin.selector);
        riskConfig.setFeeCut(address(adapter), CUT);
    }

    /// @notice feesOwed shows what the holder gets; the collect pays exactly that, and the DAO the rest
    function test_collectFees_paysTheHolderTheNetAndTheDaoTheCut() public {
        riskConfig.setFeeCut(address(adapter), CUT);
        adapter.accrueFees(id, 1e18, 1000e6);
        (uint256 net0, uint256 net1) = adapter.feesOwed(ALICE, id);
        assertApproxEqAbs(net0, 0.98e18, 2);
        assertApproxEqAbs(net1, 980e6, 2);

        vm.expectEmit(address(adapter));
        emit ISenzuAdapter.CollectFees(ALICE, id, ALICE, net0, net1, 0.02e18, 20e6 - 1);
        vm.prank(ALICE);
        (uint256 fee0, uint256 fee1) = adapter.collectFees(ALICE, id, ALICE);

        assertEq(fee0, net0);
        assertEq(fee1, net1);
        assertEq(weth.balanceOf(ALICE), net0);
        assertEq(usdc.balanceOf(ALICE), net1);
        assertEq(weth.balanceOf(DAO), 0.02e18, "2% of the 1e18 owed");
        assertEq(usdc.balanceOf(DAO), 20e6 - 1, "2% of the 1000e6 - 1 owed, rounded down");
        assertEq(weth.balanceOf(ALICE) + weth.balanceOf(DAO), 1e18, "pay + cut = what was owed");
    }

    /// @notice A redeem of every unit pays the fees the same way
    function test_redeemAll_paysTheCut() public {
        riskConfig.setFeeCut(address(adapter), CUT);
        adapter.accrueFees(id, 1e18, 0);
        (uint256 net0,) = adapter.feesOwed(ALICE, id);

        vm.prank(ALICE);
        (uint256 out0,) = collateral.redeem(ALICE, id, L, ALICE, "");
        assertEq(weth.balanceOf(ALICE), out0 + net0);
        assertEq(weth.balanceOf(DAO), 0.02e18);
    }

    /// @notice A liquidator's fees from seized units pay the cut too
    function test_formerHolderAfterASeize_paysTheCut() public {
        riskConfig.setFeeCut(address(adapter), CUT);
        (uint256 carol,) = _liquidatePart(CAROL);
        adapter.accrueFees(id, 2e18, 0);
        (uint256 net0,) = adapter.feesOwed(CAROL, id);
        uint256 daoBefore = weth.balanceOf(DAO);

        vm.prank(CAROL);
        (uint256 out0,) = collateral.redeem(CAROL, id, carol, CAROL, "");
        assertEq(weth.balanceOf(CAROL), out0 + net0);
        assertApproxEqAbs(weth.balanceOf(DAO) - daoBefore, _gross(net0) - net0, 1);
    }

    /// @notice The rate is read at payout (fees accrued before a change pay the new rate), and the cut goes wherever
    ///         `protocolReserves` points then
    function test_cut_isReadAtPayout_andFollowsProtocolReserves() public {
        adapter.accrueFees(id, 1e18, 0);
        riskConfig.setFeeCut(address(adapter), CUT);
        address newReserves = address(0xFEE);
        factory.setProtocolReserves(newReserves);

        vm.prank(ALICE);
        adapter.collectFees(ALICE, id, ALICE);
        assertEq(weth.balanceOf(newReserves), 0.02e18);
        assertEq(weth.balanceOf(DAO), 0);
    }

    /// @notice Rounded down: fees too small to cut are all the holder's
    function test_tinyFees_areAllTheHolders() public {
        riskConfig.setFeeCut(address(adapter), CUT);
        adapter.accrueFees(id, 50, 0);
        vm.prank(ALICE);
        (uint256 fee0,) = adapter.collectFees(ALICE, id, ALICE);
        assertGt(fee0, 0);
        assertEq(weth.balanceOf(DAO), 0);
        assertEq(weth.balanceOf(ALICE), fee0);
    }

    function test_noCut_sendsNothingToTheDao() public {
        adapter.accrueFees(id, 1e18, 0);
        vm.prank(ALICE);
        (uint256 fee0,) = adapter.collectFees(ALICE, id, ALICE);
        assertEq(fee0, 1e18);
        assertEq(weth.balanceOf(DAO), 0);
    }
}
