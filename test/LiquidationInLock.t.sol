// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../src/interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "../src/interfaces/ISenzuLockCallback.sol";
import {HealthMath} from "../src/libraries/HealthMath.sol";
import {SenzuBaseRouter} from "../src/periphery/SenzuBaseRouter.sol";
import {MockERC20, MockSwapRouter} from "./mocks/Mocks.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {lockLiquidator} from "./utils/LockLiquidator.sol";
import {RouterPlan} from "./utils/RouterPlan.sol";

/// @dev A capital-free liquidator: liquidates inside a lock (seize first), redeems the units, "swaps" WETH to USDC at a
///      fixed price (burn and mint) and settles the repayment. Other modes misbehave on purpose.
contract FlashLiquidatorMock is ISenzuLockCallback {
    enum Mode {
        Pay,
        DontPay,
        SliceTwice,
        ResolveAfter,
        Overpay
    }

    ISenzuCollateral immutable collateral;
    address immutable borrowable;
    MockERC20 immutable weth;
    MockERC20 immutable usdc;
    uint256 immutable ethPrice; // whole USD per ETH

    uint256 public seized;
    uint256 public repaid;

    constructor(
        ISenzuCollateral collateral_,
        address borrowable_,
        MockERC20 weth_,
        MockERC20 usdc_,
        uint256 ethPrice_
    ) {
        (collateral, borrowable, weth, usdc, ethPrice) = (collateral_, borrowable_, weth_, usdc_, ethPrice_);
    }

    function liquidate(address borrower, uint256 id, Mode mode) external {
        collateral.lock(abi.encode(borrower, id, mode));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        (address borrower, uint256 id, Mode mode) = abi.decode(data, (address, uint256, Mode));
        if (mode == Mode.SliceTwice) {
            uint256 slice = ISenzuBorrowable(borrowable).debtOf(borrower, id, address(usdc)) / 50;
            (uint256 s1, uint256 r1, uint256 f1) =
                collateral.liquidate(borrower, id, address(usdc), slice, address(this));
            uint256 slice2 = ISenzuBorrowable(borrowable).debtOf(borrower, id, address(usdc)) / 50;
            (uint256 s2, uint256 r2, uint256 f2) =
                collateral.liquidate(borrower, id, address(usdc), slice2, address(this));
            (seized, repaid) = (s1 + s2, r1 + r2);
            uint256 due = repaid + f1 + f2;
            usdc.mint(address(this), due);
            usdc.approve(borrowable, due);
            collateral.settle(address(usdc), due);
            return "";
        }

        uint256 fee;
        (seized, repaid, fee) = collateral.liquidate(borrower, id, address(usdc), type(uint256).max, address(this));
        uint256 totalDue = repaid + fee;
        if (mode == Mode.Pay) {
            collateral.redeem(address(this), id, seized, address(this), "");
            uint256 wethBalance = weth.balanceOf(address(this));
            weth.burn(address(this), wethBalance);
            usdc.mint(address(this), wethBalance * ethPrice / 1e12);
            usdc.approve(borrowable, totalDue);
            collateral.settle(address(usdc), totalDue);
        } else if (mode == Mode.ResolveAfter) {
            collateral.resolveBadDebt(borrower, id);
        } else if (mode == Mode.Overpay) {
            usdc.mint(address(this), totalDue + 1);
            usdc.approve(borrowable, totalDue + 1);
            collateral.settle(address(usdc), totalDue + 1);
        }
        return "";
    }
}

/// @dev Opens a lock and calls `target` from inside it
contract LockThenCall is ISenzuLockCallback {
    ISenzuCollateral immutable collateral;

    constructor(ISenzuCollateral collateral_) {
        collateral = collateral_;
    }

    function run(address target, bytes calldata call) external {
        collateral.lock(abi.encode(target, call));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        (address target, bytes memory call) = abi.decode(data, (address, bytes));
        (bool ok, bytes memory ret) = target.call(call);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return "";
    }
}

contract Bystander {
    function liquidate(ISenzuCollateral collateral, address borrower, uint256 id, address asset) external {
        collateral.liquidate(borrower, id, asset, type(uint256).max, address(this));
    }

    function settle(ISenzuCollateral collateral, address asset, uint256 assets) external {
        collateral.settle(asset, assets);
    }
}

contract LiquidationInLockTest is HubFixture {
    using RouterPlan for RouterPlan.Plan;

    uint256 debt;
    FlashLiquidatorMock liquidator;

    function setUp() public override {
        super.setUp();
        // Penalty and seizure math without the protocol's liquidation fee (LiquidationFee.t.sol covers the fee)
        riskConfig.setLiquidationFee(address(adapter), 0);

        // Alice borrows 80% of her collateral, then ETH drops 20%: liquidatable, not underwater
        debt = _usdcFor(0.8e18);
        _borrow(ALICE, address(usdc), debt);
        ethFeed.set(1600e8, block.timestamp);
        adapter.setPoolSqrtPrice(HealthMath.sqrtPriceX96FromUsd(1600e18, 1e18, 18, 6));
        assertTrue(collateral.health(ALICE, id).minSurplusUsdWad < 0);

        liquidator = new FlashLiquidatorMock(collateral, address(borrowable), weth, usdc, 1600);
    }

    /*  ================================================
                       Seize, then repay
        ================================================  */

    function test_liquidateInALock_needsNoCapitalAndMatchesLiquidate() public {
        // Reference: the same liquidation paid up front
        uint256 snapshot = vm.snapshotState();
        usdc.mint(CAROL, debt);
        vm.startPrank(CAROL);
        usdc.approve(address(borrowable), type(uint256).max);
        (uint256 refSeized,) =
            lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), type(uint256).max, CAROL);
        vm.stopPrank();
        uint256 refDebt = borrowable.debtOf(ALICE, id, address(usdc));
        vm.revertToState(snapshot);

        assertEq(usdc.balanceOf(address(liquidator)), 0, "starts with nothing");
        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.Pay);

        assertEq(liquidator.seized(), refSeized, "same units as liquidate");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), refDebt, "same repayment as liquidate");
        assertEq(collateral.balanceOf(DAO, id), 0, "nothing to protocolReserves");
        assertApproxEqAbs(liquidator.repaid(), debt, 1, "the whole debt");
        assertGt(usdc.balanceOf(address(liquidator)), 0, "the incentive is left over as profit");
        assertEq(collateral.balanceOf(address(liquidator), id), 0, "seized units redeemed");
        _assertSupplyMatchesAdapter(id);
    }

    function test_liquidateInALock_unsettledRevertsTheSeize() public {
        uint256 units = collateral.balanceOf(ALICE, id);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Unsettled.selector);
        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.DontPay);

        assertEq(collateral.balanceOf(ALICE, id), units, "nothing seized");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), debt, "nothing repaid");
    }

    /*  ================================================
                             Guards
        ================================================  */

    function test_liquidate_outsideALockReverts() public {
        vm.prank(CAROL);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLocker.selector);
        collateral.liquidate(ALICE, id, address(usdc), type(uint256).max, CAROL);
    }

    /// @dev Only the lock holder liquidates (as Ekubo's locker): a contract it calls can't add a repayment to what the
    ///      holder's lock owes, so it can neither make the holder pay for it nor revert the holder's lock
    function test_liquidate_byABystanderInsideALockReverts() public {
        LockThenCall locker = new LockThenCall(collateral);
        Bystander bystander = new Bystander();
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLocker.selector);
        locker.run(address(bystander), abi.encodeCall(Bystander.liquidate, (collateral, ALICE, id, address(usdc))));
    }

    /// @dev Nor settles: only the holder pays what its lock owes
    function test_settle_byABystanderInsideALockReverts() public {
        LockThenCall locker = new LockThenCall(collateral);
        Bystander bystander = new Bystander();
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLocker.selector);
        locker.run(address(bystander), abi.encodeCall(Bystander.settle, (collateral, address(usdc), 0)));
    }

    /// @dev Paying more than the lock owes would pay for someone else's liquidation
    function test_settle_moreThanUnsettledReverts() public {
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__MoreThanUnsettled.selector);
        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.Overpay);

        LockThenCall locker = new LockThenCall(collateral);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__MoreThanUnsettled.selector);
        locker.run(address(collateral), abi.encodeCall(ISenzuCollateral.settle, (address(usdc), 1)));

        vm.prank(CAROL);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLocker.selector);
        collateral.settle(address(usdc), 1);
    }

    /// @dev The repayment is booked when the units are seized, so a second liquidation in the same lock sees the
    ///      reduced debt: two 2% slices in one lock seize what they seize in two locks
    function test_liquidateInALock_secondLiquidationSeesTheRepaidDebt() public {
        uint256 snapshot = vm.snapshotState();
        usdc.mint(CAROL, debt);
        vm.startPrank(CAROL);
        uint256 slice = borrowable.debtOf(ALICE, id, address(usdc)) / 50;
        (uint256 s1,) = lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), slice, CAROL);
        uint256 slice2 = borrowable.debtOf(ALICE, id, address(usdc)) / 50;
        (uint256 s2,) = lockLiquidator().liquidate(collateral, ALICE, id, address(usdc), slice2, CAROL);
        vm.stopPrank();
        uint256 refDebt = borrowable.debtOf(ALICE, id, address(usdc));
        vm.revertToState(snapshot);

        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.SliceTwice);
        assertEq(liquidator.seized(), s1 + s2, "same units as two locks");
        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), refDebt, "same debt left");
    }

    /// @dev resolveBadDebt never runs inside a lock (audit 2026-10-05)
    function test_liquidateInALock_noBadDebtWriteOffInTheSameLock() public {
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__Locked.selector);
        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.ResolveAfter);
    }

    function test_settle_zeroPaysNothing() public {
        uint256 cash = usdc.balanceOf(address(borrowable));
        LockThenCall locker = new LockThenCall(collateral);
        locker.run(address(collateral), abi.encodeCall(ISenzuCollateral.settle, (address(usdc), 0)));
        assertEq(usdc.balanceOf(address(borrowable)), cash);
    }

    function test_liquidateInALock_healthyPositionReverts() public {
        ethFeed.set(2000e8, block.timestamp);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__NotLiquidatable.selector);
        liquidator.liquidate(ALICE, id, FlashLiquidatorMock.Mode.Pay);
    }

    /*  ================================================
                       Through the router
        ================================================  */

    function test_router_liquidateRedeemSwapWithNoCapital() public {
        // Sells WETH for USDC at $1600
        MockSwapRouter senzuRouter = new MockSwapRouter(address(collateral), address(weth), address(0));
        senzuRouter.setRate(address(weth), address(usdc), 1600e6, 1e18);
        vm.prank(CAROL);
        collateral.setOperator(address(senzuRouter), true);

        RouterPlan.Plan memory p;
        p = p.liquidate(ALICE, id, address(usdc), type(uint256).max);
        p = p.redeem(id, type(uint256).max, 0, 0); // Carol's seized units in Alice's position
        p = p.swap(address(weth), address(usdc), type(uint256).max, 0, "");
        vm.prank(CAROL);
        senzuRouter.execute(p.actions, p.params, block.timestamp, false);

        assertEq(borrowable.debtOf(ALICE, id, address(usdc)), 0, "the whole debt");
        assertGt(usdc.balanceOf(CAROL), 0, "profit, from no capital");
        assertEq(collateral.balanceOf(CAROL, id), 0);
        assertEq(usdc.balanceOf(address(senzuRouter)), 0, "router holds nothing");
        assertEq(usdc.allowance(address(senzuRouter), address(borrowable)), type(uint256).max, "standing approval");
    }
}
