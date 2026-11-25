// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {ISenzuCollateral} from "src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "src/interfaces/ISenzuLockCallback.sol";

/// @dev Opens a lock and makes any calls inside it, to the collateral or the borrowable, as an integrator would
contract LockActor is ISenzuLockCallback {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable collateral;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    function run(Call[] memory calls) external {
        ISenzuCollateral(collateral).lock(abi.encode(calls));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == collateral, "not collateral");
        Call[] memory calls = abi.decode(data, (Call[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = calls[i].target.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return "";
    }
}

/**
 *  @notice The intended invariants that no other test checks directly, one test each, named by number.
 *          The rest are proven by the invariant handler (`test/invariant/`) and the other tests.
 */
contract InvariantsTest is HubFixture {
    LockActor actor;

    function setUp() public override {
        super.setUp();
        // Penalty and seizure math without the protocol's liquidation fee (LiquidationFee.t.sol covers the fee)
        riskConfig.setLiquidationFee(address(adapter), 0);
        actor = new LockActor(address(collateral));
    }

    function _call(address target, bytes memory data) internal pure returns (LockActor.Call memory) {
        return LockActor.Call(target, data);
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp(); // via-IR can keep one block.timestamp read across warps
    }

    function _lastAccrual(address asset) internal view returns (uint256) {
        return borrowable.getMarket(asset).lastAccrual;
    }

    /*  ========================================================
             2. A position without collateral cannot borrow
        ========================================================  */

    /// @dev Outside a lock: an account with no units in the position can't borrow against it
    function test_inv2_noUnitsNoBorrow() public {
        assertEq(collateral.balanceOf(BOB, id), 0);
        vm.prank(BOB);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.borrow(BOB, id, address(usdc), 1e6, BOB);
    }

    /// @dev Inside a lock it may, if the same lock repays: the check at its end sees no debt. Without the repay the
    ///      whole lock reverts
    function test_inv2_borrowRepaidInTheSameLockEndsClean() public {
        uint256 cash = 100_000e6;
        LockActor.Call[] memory calls = new LockActor.Call[](3);
        calls[0] = _call(
            address(collateral),
            abi.encodeCall(collateral.borrow, (address(actor), id, address(usdc), cash, address(actor)))
        );
        calls[1] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(borrowable), type(uint256).max)));
        calls[2] = _call(
            address(borrowable),
            abi.encodeCall(borrowable.repay, (address(actor), id, address(usdc), type(uint256).max))
        );
        usdc.mint(address(actor), 1e6); // the borrow fee is 0, but leave room for a unit of rounding
        actor.run(calls);
        assertFalse(borrowable.hasDebt(address(actor), id), "ends clean");

        LockActor.Call[] memory unpaid = new LockActor.Call[](1);
        unpaid[0] = calls[0];
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        actor.run(unpaid);
    }

    /*  ================================================================================
             3. A liquidatable position can't redeem one wei (units don't transfer)
        ================================================================================  */

    function test_inv3_liquidatablePositionCantMoveOneWei() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.8e18));
        ethFeed.set(1600e8, _now());
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        vm.startPrank(ALICE);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        collateral.redeem(ALICE, id, 1, ALICE, "");
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NonTransferable.selector);
        collateral.transfer(BOB, id, 1);
        vm.stopPrank();

        assertEq(collateral.balanceOf(ALICE, id), L, "not one wei moved");
    }

    /*  ============================================================
            9. Interest accrues before every change of a market
        ============================================================  */

    /// @dev Every action that changes a market brings its interest up to now first: supply, withdraw, borrow, repay,
    ///      repayFor (liquidation), writeOff (the liquidation that takes the last unit). The admin setter has its own test
    ///      (`test_setReserveFactor_accruesFirst`)
    function test_inv9_everyMarketChangeAccruesFirst() public {
        address u = address(usdc);
        _borrow(ALICE, u, _usdcFor(0.8e18)); // borrows, so time accrues interest (and $1300 ETH leaves bad debt)

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(2000e8, _now());
        vm.prank(BOB);
        borrowable.supply(u, 1e6, BOB);
        assertEq(_lastAccrual(u), _now(), "supply");

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(2000e8, _now());
        vm.prank(BOB);
        borrowable.withdraw(u, 1e6, BOB, BOB);
        assertEq(_lastAccrual(u), _now(), "withdraw");

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(2000e8, _now());
        _borrow(ALICE, u, 1e6);
        assertEq(_lastAccrual(u), _now(), "borrow");

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(2000e8, _now());
        usdc.mint(ALICE, 1e6);
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, u, 1e6);
        vm.stopPrank();
        assertEq(_lastAccrual(u), _now(), "repay");

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(1300e8, _now()); // underwater
        usdc.mint(BOB, 1_000_000e6);
        uint256 tenth = borrowable.debtOf(ALICE, id, u) / 10;
        vm.prank(BOB);
        lockLiquidator().liquidate(collateral, ALICE, id, u, tenth, BOB);
        assertEq(_lastAccrual(u), _now(), "repayFor");

        vm.warp(_now() + 1 hours); // under the USDC feed's 1-day heartbeat
        ethFeed.set(1300e8, _now());
        vm.prank(BOB);
        lockLiquidator().liquidate(collateral, ALICE, id, u, type(uint256).max, BOB);
        assertFalse(borrowable.hasDebt(ALICE, id), "the rest written off");
        assertEq(_lastAccrual(u), _now(), "writeOff");
    }

    /*  ================================================
               24. Nothing of a lock survives it
        ================================================  */

    /// @dev Two locks in one transaction (a test function is one): the second starts clean. A settled liquidation in
    ///      the first leaves nothing owed behind (the second can liquidate the same position again), and
    ///      after the lock, a borrow against an id not opened yet is refused again (only a lock allows it)
    function test_inv24_aLockLeavesNothingBehind() public {
        _borrow(ALICE, address(usdc), _usdcFor(0.8e18));
        ethFeed.set(1600e8, _now());
        usdc.mint(address(actor), 1_000_000e6);

        LockActor.Call[] memory calls = new LockActor.Call[](3);
        calls[0] = _call(address(usdc), abi.encodeCall(usdc.approve, (address(borrowable), type(uint256).max)));
        calls[1] = _call(
            address(collateral), abi.encodeCall(collateral.liquidate, (ALICE, id, address(usdc), 10e6, address(actor)))
        );
        calls[2] = _call(address(collateral), abi.encodeCall(collateral.settle, (address(usdc), 10e6)));
        actor.run(calls);
        uint256 afterFirst = borrowable.debtOf(ALICE, id, address(usdc));
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0, "still liquidatable after a 10 USDC repay");

        actor.run(calls); // same transaction: nothing of the first lock is owed
        // A repay burns shares rounded down (invariant 25), so the debt falls by the repay or one unit less
        assertApproxEqAbs(borrowable.debtOf(ALICE, id, address(usdc)), afterFirst - 10e6, 1, "liquidated again");

        uint256 next = collateral.nextPositionId();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__PositionNotFound.selector, next));
        collateral.borrow(ALICE, next, address(usdc), 1e6, ALICE);
    }

    /*  ================================================
            25. Rounding never gives anyone a profit
        ================================================  */

    /// @dev Borrow then repay everything, after any wait: the borrower pays back at least what it got
    function testFuzz_inv25_borrowThenRepayNeverProfits(uint256 amount, uint256 wait) public {
        amount = bound(amount, 1, _usdcFor(0.8e18));
        _borrow(ALICE, address(usdc), amount);
        assertGt(borrowable.borrowSharesOf(ALICE, id, address(usdc)), 0, "a borrow books shares");
        assertGe(borrowable.debtOf(ALICE, id, address(usdc)), amount, "debt is at least what was borrowed");

        vm.warp(_now() + bound(wait, 0, 365 days));
        uint256 balance = usdc.balanceOf(ALICE);
        usdc.mint(ALICE, amount); // enough for any interest
        vm.startPrank(ALICE);
        usdc.approve(address(borrowable), type(uint256).max);
        borrowable.repay(ALICE, id, address(usdc), type(uint256).max);
        vm.stopPrank();

        uint256 paid = balance + amount - usdc.balanceOf(ALICE);
        assertGe(paid, amount, "repaid less than borrowed");
        assertFalse(borrowable.hasDebt(ALICE, id));
    }

    /// @dev The smallest borrow still books debt: one wei borrowed is owed
    function test_inv25_oneWeiBorrowIsOwed() public {
        _borrow(ALICE, address(usdc), 1);
        assertGe(borrowable.debtOf(ALICE, id, address(usdc)), 1);
        assertEq(usdc.balanceOf(ALICE), 1);
    }
}
