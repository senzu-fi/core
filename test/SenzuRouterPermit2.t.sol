// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuRouter} from "../src/interfaces/ISenzuRouter.sol";
import {lenderId} from "../src/libraries/Types.sol";
import {MockERC20, MockPermit2, MockSwapRouter, MockWETH} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {RouterPlan} from "./utils/RouterPlan.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

contract SenzuRouterPermit2Test is HubFixture {
    using RouterPlan for RouterPlan.Plan;

    uint256 constant ALL = type(uint256).max;

    MockSwapRouter senzuRouter;
    MockPermit2 permit2;

    function setUp() public override {
        super.setUp();
        vm.etch(address(weth), address(new MockWETH()).code);
        senzuRouter = new MockSwapRouter(address(collateral), address(weth), address(0));
        vm.etch(SafeTransferLib.PERMIT2, address(new MockPermit2()).code);
        permit2 = MockPermit2(SafeTransferLib.PERMIT2);
    }

    function _run(address caller, RouterPlan.Plan memory p) internal returns (uint256) {
        vm.prank(caller);
        return senzuRouter.execute(p.actions, p.params, block.timestamp, false);
    }

    function _batch(address token, uint160 amount) internal view returns (IAllowanceTransfer.PermitBatch memory batch) {
        batch.details = new IAllowanceTransfer.PermitDetails[](1);
        batch.details[0] = IAllowanceTransfer.PermitDetails(token, amount, uint48(block.timestamp + 1 days), 0);
        batch.spender = address(senzuRouter);
        batch.sigDeadline = block.timestamp;
    }

    /// @dev A wallet that approved Permit2 only: its signature in the same call lets the router pull its tokens
    function test_permit2_pullsWithoutARouterApproval() public {
        usdc.mint(CAROL, 500e6);
        vm.prank(CAROL);
        usdc.approve(address(permit2), type(uint256).max);

        RouterPlan.Plan memory p;
        p = p.permit(_batch(address(usdc), 500e6), "");
        p = p.pull(address(usdc), 500e6);
        p = p.supply(address(usdc), ALL);
        _run(CAROL, p);

        assertEq(permit2.lastOwner(), CAROL, "the permit is the caller's");
        assertEq(usdc.balanceOf(CAROL), 0);
        assertGt(borrowable.balanceOf(CAROL, lenderId(address(usdc))), 0);
    }

    /// @dev `swap` pulls through Permit2 too
    function test_permit2_swapOutsideALock() public {
        usdc.mint(CAROL, 1_000e6);
        vm.prank(CAROL);
        usdc.approve(address(permit2), type(uint256).max);
        vm.prank(address(0xDEAD));
        permit2.permit(CAROL, _batch(address(usdc), 1_000e6), "");

        vm.prank(CAROL);
        senzuRouter.swap(address(usdc), address(weth), 1_000e6, 1, abi.encode(uint256(0.5e18)));
        assertEq(weth.balanceOf(CAROL), 0.5e18);
    }

    function test_permit2_noApprovalAtAllReverts() public {
        usdc.mint(CAROL, 500e6);
        RouterPlan.Plan memory p;
        p = p.pull(address(usdc), 500e6);
        vm.expectRevert(SafeTransferLib.TransferFromFailed.selector);
        _run(CAROL, p);
    }

    function test_rewardsActionsOnlyWhereTheDexHasThem() public {
        vm.prank(ALICE);
        collateral.setOperator(address(senzuRouter), true);
        RouterPlan.Plan memory p;
        vm.expectRevert(
            abi.encodeWithSelector(
                ISenzuRouter.SenzuRouter__UnsupportedAction.selector, uint8(ISenzuRouter.Action.ClaimRewards)
            )
        );
        _run(ALICE, p.claimRewards(id));

        RouterPlan.Plan memory dexStep;
        vm.expectRevert(abi.encodeWithSelector(ISenzuRouter.SenzuRouter__UnsupportedAction.selector, uint8(128)));
        _run(ALICE, dexStep.dex(128, ""));
    }
}
