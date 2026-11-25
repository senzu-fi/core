// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {LockScript} from "./BorrowBeforeOpen.t.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";

/// @dev Somewhere outside the protocol the loan is used, and comes back from
contract Elsewhere {
    function giveBack(MockERC20 token, address to, uint256 amount) external {
        token.transfer(to, amount);
    }
}

/**
 *  @notice Flash borrows (decided 2026-11-12): inside a lock a borrow's health check waits for the lock's end, and an
 *          id not opened yet is accepted (so a leveraged open borrows before it mints). A contract with no position
 *          borrows a market's cash against `nextPositionId()`, uses it anywhere, and repays it before the lock ends:
 *          with no debt left there is nothing to check. It costs the borrow fee only, paid to the reserves
 */
contract FlashBorrowTest is HubFixture {
    LockScript script;
    Elsewhere elsewhere;

    function setUp() public override {
        super.setUp();
        script = new LockScript(collateral);
        elsewhere = new Elsewhere();
    }

    function _calls(uint256 amount, uint256 repayAssets) internal view returns (LockScript.Call[] memory) {
        return _calls(collateral.nextPositionId(), address(script), amount, repayAssets);
    }

    function _calls(uint256 id, address account, uint256 amount, uint256 repayAssets)
        internal
        view
        returns (LockScript.Call[] memory calls)
    {
        address s = address(script);
        calls = new LockScript.Call[](5);
        calls[0] = LockScript.Call(
            address(collateral), abi.encodeCall(collateral.borrow, (account, id, address(usdc), amount, s))
        );
        calls[1] = LockScript.Call(address(usdc), abi.encodeCall(usdc.transfer, (address(elsewhere), amount)));
        calls[2] = LockScript.Call(address(elsewhere), abi.encodeCall(elsewhere.giveBack, (usdc, s, amount)));
        calls[3] = LockScript.Call(address(usdc), abi.encodeCall(usdc.approve, (address(borrowable), repayAssets)));
        calls[4] = LockScript.Call(
            address(borrowable), abi.encodeCall(borrowable.repay, (account, id, address(usdc), repayAssets))
        );
    }

    function test_flashBorrow_withoutAPosition() public {
        uint256 amount = 900_000e6;
        usdc.mint(address(script), 10_000e6);
        uint256 cash = usdc.balanceOf(address(borrowable));
        uint256 next = collateral.nextPositionId();

        script.run(_calls(amount, amount));

        assertFalse(borrowable.hasDebt(address(script), next), "no debt left");
        assertEq(collateral.nextPositionId(), next, "no position opened");
        assertEq(usdc.balanceOf(address(borrowable)), cash, "the market got its cash back");
        assertEq(usdc.balanceOf(address(script)), 10_000e6, "no borrow fee set: free");
    }

    function test_flashBorrow_paysTheBorrowFeeToTheReserves() public {
        riskConfig.setBorrowFee(address(adapter), 0.001e18);
        uint256 amount = 900_000e6;
        usdc.mint(address(script), 10_000e6);
        uint256 cash = usdc.balanceOf(address(borrowable));
        uint256 next = collateral.nextPositionId();

        // The fee is added to the debt: repaying the amount borrowed plus 0.1% clears it
        script.run(_calls(amount, amount + amount / 1000 + 1));

        assertFalse(borrowable.hasDebt(address(script), next), "no debt left");
        uint256 paid = 10_000e6 - usdc.balanceOf(address(script));
        assertApproxEqAbs(paid, amount / 1000, 2, "it cost the borrow fee");
        assertEq(usdc.balanceOf(address(borrowable)), cash + paid, "the fee stayed in the market");
    }

    /// @dev A wei of debt left on an id nobody opened fails the end-of-lock check
    function test_flashBorrow_unpaidReverts() public {
        uint256 amount = 900_000e6;
        LockScript.Call[] memory calls = _calls(amount, amount - 1);
        vm.expectRevert();
        script.run(calls);
    }

    /// @dev A debt is an account's on a position, backed by that account's units only: borrowing on Alice's id as
    ///      itself, the script owes nothing of hers and is backed by none of her units
    function test_flashBorrow_onSomeoneElsesId() public {
        _borrow(ALICE, address(usdc), 1_000e6);
        uint256 aliceDebt = borrowable.debtOf(ALICE, id, address(usdc));
        int256 aliceSurplus = collateral.health(ALICE, id).minSurplusUsdWad;
        uint256 amount = 900_000e6;

        script.run(_calls(id, address(script), amount, amount));
        assertFalse(borrowable.hasDebt(address(script), id), "repaid");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), aliceDebt, "Alice's debt untouched");
        assertEq(collateral.health(ALICE, id).minSurplusUsdWad, aliceSurplus, "Alice's health untouched");

        // Left unpaid, the script's own units (none) back it: the lock reverts
        LockScript.Call[] memory calls = _calls(id, address(script), amount, amount - 1);
        vm.expectRevert();
        script.run(calls);

        // And it can't borrow as Alice: only she or her operator can
        calls = _calls(id, ALICE, amount, amount);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Unauthorized.selector);
        script.run(calls);
    }
}
