// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "../src/interfaces/ISenzuLockCallback.sol";
import {HubFixture} from "./utils/HubFixture.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

/// @dev Runs (target, calldata) pairs inside one lock, reverting with the first failure's data
contract LockScript is ISenzuLockCallback {
    struct Call {
        address target;
        bytes data;
    }

    ISenzuCollateral immutable collateral;

    constructor(ISenzuCollateral collateral_) {
        collateral = collateral_;
    }

    function run(Call[] memory calls) external {
        collateral.lock(abi.encode(calls));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
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

/// @dev Another contract opening a position inside the same lock (a callback the locker's code reached)
contract Outsider {
    function open(ISenzuCollateral collateral, bytes calldata data, address to) external {
        collateral.open(to, address(this), data);
    }
}

/**
 *  @notice Borrowing before the position exists (decided 2026-10-15, replacing reserve and fund): inside a lock an
 *          account borrows against `nextPositionId()`, then `open` creates that id, so a leveraged open mints once.
 *          Nothing is reserved: the end-of-lock health check fails unless the id was opened and the borrower holds
 *          its units.
 */
contract BorrowBeforeOpenTest is HubFixture {
    LockScript script;

    function setUp() public override {
        super.setUp();
        script = new LockScript(collateral);
        vm.prank(ALICE);
        collateral.setOperator(address(script), true);
    }

    /*  ================================================
                            Helpers
        ================================================  */

    function _mintData(uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(address(weth), address(usdc), TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, liquidity);
    }

    function _call(bytes memory data) internal view returns (LockScript.Call memory) {
        return LockScript.Call(address(collateral), data);
    }

    function _borrowCall(uint256 positionId, uint256 amount) internal view returns (LockScript.Call memory) {
        return _call(abi.encodeCall(collateral.borrow, (ALICE, positionId, address(usdc), amount, ALICE)));
    }

    function _openCall(uint128 liquidity, address to) internal view returns (LockScript.Call memory) {
        return _call(abi.encodeCall(collateral.open, (to, address(script), _mintData(liquidity))));
    }

    function _run(LockScript.Call[] memory calls) internal {
        script.run(calls);
    }

    /*  ================================================
                             Tests
        ================================================  */

    /// @dev A leveraged open in one mint: borrow against the next id, then open it with margin and loan
    function test_borrowBeforeOpen_opensWithOneMint() public {
        uint256 next = collateral.nextPositionId();
        uint256 amount = _usdcFor(0.5e18);
        LockScript.Call[] memory calls = new LockScript.Call[](2);
        calls[0] = _borrowCall(next, amount);
        calls[1] = _openCall(L, ALICE);
        _run(calls);

        assertEq(collateral.nextPositionId(), next + 1, "one new position");
        assertEq(collateral.balanceOf(ALICE, next), L);
        assertEq(borrowable.debtOf(ALICE, next, address(usdc)), amount);
        assertFalse(collateral.health(ALICE, next).minSurplusUsdWad < 0);
        _assertSupplyMatchesAdapter(next);
    }

    /// @dev The end-of-lock check still runs: an open too small for the debt reverts like a borrow without collateral
    function test_borrowBeforeOpen_stillCheckedWhenTheLockEnds() public {
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](2);
        calls[0] = _borrowCall(next, _usdcFor(0.9e18)); // 0.9x of an L position
        calls[1] = _openCall(L / 2, ALICE); // only half of it
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        _run(calls);
    }

    /// @dev Debt never outlives the lock without its position: a borrow against an id nobody opens reverts the lock
    function test_borrowWithoutOpenRevertsTheLock() public {
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](1);
        calls[0] = _borrowCall(next, _usdcFor(0.1e18));
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__PositionNotFound.selector, next));
        _run(calls);
    }

    /// @dev The units, not the id, back the debt: opened to someone else, the borrower holds none and the lock reverts
    function test_openedForAnotherAccountRevertsTheLock() public {
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](2);
        calls[0] = _borrowCall(next, _usdcFor(0.1e18));
        calls[1] = _openCall(L, BOB);
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        _run(calls);
    }

    /// @dev Nothing to front-run: if something else opens the id first (only possible inside the locker's own lock),
    ///      the locker's open gets the next one, its debt has no units behind it, and only its own lock reverts
    function test_anotherOpenFirstOnlyFailsTheLockersOwnLock() public {
        Outsider outsider = new Outsider();
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](3);
        calls[0] = _borrowCall(next, _usdcFor(0.1e18));
        calls[1] = LockScript.Call(address(outsider), abi.encodeCall(Outsider.open, (collateral, _mintData(L), BOB)));
        calls[2] = _openCall(L, ALICE); // gets next + 1
        vm.expectRevert(ISenzuCollateral.SenzuCollateral__InsufficientCollateral.selector);
        _run(calls);
        assertEq(collateral.nextPositionId(), next, "nothing happened");
    }

    /// @dev Outside a lock the position must exist: there is no check to come
    function test_noBorrowAgainstAnUnopenedIdOutsideALock() public {
        uint256 next = collateral.nextPositionId();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__PositionNotFound.selector, next));
        collateral.borrow(ALICE, next, address(usdc), 1e6, ALICE);
    }

    /// @dev Ids stay sequential and are never reused: a borrow takes none, only an open does
    function test_idsStaySequential() public {
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](3);
        calls[0] = _borrowCall(next, _usdcFor(0.1e18));
        calls[1] = _openCall(L, ALICE);
        calls[2] = _openCall(L, ALICE); // a second, plain open
        _run(calls);
        assertEq(collateral.nextPositionId(), next + 2);
    }

    /// @dev An id with a debt waiting for its end-of-lock check can't be liquidated in the meantime
    function test_unopenedIdCantBeLiquidated() public {
        uint256 next = collateral.nextPositionId();
        LockScript.Call[] memory calls = new LockScript.Call[](2);
        calls[0] = _borrowCall(next, _usdcFor(0.1e18));
        calls[1] = _call(abi.encodeCall(collateral.liquidate, (ALICE, next, address(usdc), type(uint256).max, BOB)));
        vm.expectRevert(abi.encodeWithSelector(ISenzuCollateral.SenzuCollateral__CheckPending.selector, ALICE, next));
        _run(calls);
    }
}
