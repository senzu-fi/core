// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Timelocked} from "../script/Timelocked.sol";
import {ISenzuFactory} from "../src/interfaces/ISenzuFactory.sol";
import {SenzuFactory} from "../src/modules/SenzuFactory.sol";
import {BorrowableDeployer} from "../src/modules/deployers/BorrowableDeployer.sol";
import {CollateralDeployer} from "../src/modules/deployers/CollateralDeployer.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {Test} from "forge-std/Test.sol";

/// @notice OpenZeppelin's TimelockController as the factory admin, set up as the deploy script does: one proposer and
///         executor, no role admin but the timelock itself. A zero delay runs at once (before launch); every change,
///         the delay's and the roles' included, waits the current delay
contract TimelockTest is Test {
    address constant OWNER = address(0x0A11);
    address constant GUARDIAN = address(0x6A6D);

    TimelockController timelock;
    SenzuFactory factory;

    function setUp() public {
        vm.warp(1_000_000);
        address[] memory owner = new address[](1);
        owner[0] = OWNER;
        timelock = new TimelockController(0, owner, owner, address(0));
        factory = new SenzuFactory(
            address(this),
            GUARDIAN,
            address(0xDA0),
            address(new BorrowableDeployer()),
            address(new CollateralDeployer())
        );
        // Hand the factory to the timelock: it accepts through itself, at once with a zero delay
        factory.setPendingAdmin(address(timelock));
        _run(address(factory), abi.encodeCall(factory.acceptAdmin, ()));
        assertEq(factory.admin(), address(timelock));
    }

    function _run(address target, bytes memory data) internal {
        vm.startPrank(OWNER);
        Timelocked.execute(timelock, target, data);
        vm.stopPrank();
    }

    function _setGuardian(address guardian) internal pure returns (bytes memory) {
        return abi.encodeCall(ISenzuFactory.setGuardian, (guardian));
    }

    function _setDelay(uint256 newDelay) internal {
        bytes memory data = abi.encodeCall(timelock.updateDelay, (newDelay));
        vm.startPrank(OWNER);
        timelock.schedule(address(timelock), 0, data, 0, 0, timelock.getMinDelay());
        vm.warp(vm.getBlockTimestamp() + timelock.getMinDelay());
        timelock.execute(address(timelock), 0, data, 0, 0);
        vm.stopPrank();
    }

    function test_zeroDelay_runsAtOnce_andTheSameCallAgain() public {
        _run(address(factory), _setGuardian(address(0xBEEF)));
        _run(address(factory), _setGuardian(GUARDIAN));
        _run(address(factory), _setGuardian(address(0xBEEF))); // done operations stay done: the helper takes a new salt
        assertEq(factory.guardian(), address(0xBEEF));
    }

    function test_onlyTheOwnerProposesExecutesAndCancels() public {
        bytes memory data = _setGuardian(address(0xBEEF));
        vm.startPrank(address(0xBAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), timelock.PROPOSER_ROLE()
            )
        );
        timelock.schedule(address(factory), 0, data, 0, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), timelock.EXECUTOR_ROLE()
            )
        );
        timelock.execute(address(factory), 0, data, 0, 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xBAD), timelock.CANCELLER_ROLE()
            )
        );
        timelock.cancel(bytes32(0));
        vm.stopPrank();

        // And the factory takes admin calls only from the timelock now
        vm.expectRevert(ISenzuFactory.SenzuFactory__NotAdmin.selector);
        factory.setGuardian(address(0xBEEF));
    }

    /// @dev Only the timelock grants roles: nobody holds the role admin, the deployer included
    function test_noRoleAdminButTheTimelock() public view {
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), OWNER));
    }

    function test_aDelayedCallWaitsTheDelay() public {
        _setDelay(1 days);
        bytes memory data = _setGuardian(address(0xBEEF));
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 0, 1 days));
        timelock.schedule(address(factory), 0, data, 0, 0, 0);
        timelock.schedule(address(factory), 0, data, 0, 0, 1 days);

        vm.warp(vm.getBlockTimestamp() + 1 days - 1);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        timelock.execute(address(factory), 0, data, 0, 0);
        vm.stopPrank();
        assertEq(factory.guardian(), address(0xBEEF));
    }

    /// @dev Lowering the delay is itself a call that waits the current delay: users always get that much warning
    function test_theDelayChangesOnlyThroughTheTimelock_waitingTheCurrentDelay() public {
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, OWNER));
        timelock.updateDelay(0);

        _setDelay(2 days);
        assertEq(timelock.getMinDelay(), 2 days);
        bytes memory lower = abi.encodeCall(timelock.updateDelay, (1 hours));
        vm.startPrank(OWNER);
        timelock.schedule(address(timelock), 0, lower, 0, 0, 2 days);
        vm.warp(vm.getBlockTimestamp() + 2 days - 1);
        vm.expectRevert();
        timelock.execute(address(timelock), 0, lower, 0, 0);
        vm.warp(vm.getBlockTimestamp() + 1);
        timelock.execute(address(timelock), 0, lower, 0, 0);
        vm.stopPrank();
        assertEq(timelock.getMinDelay(), 1 hours);
    }

    function test_cancel() public {
        _setDelay(1 days);
        bytes memory data = _setGuardian(address(0xBEEF));
        vm.startPrank(OWNER);
        timelock.schedule(address(factory), 0, data, 0, 0, 1 days);
        bytes32 id = timelock.hashOperation(address(factory), 0, data, 0, 0);
        timelock.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, 0, 0);
        vm.stopPrank();
        assertEq(factory.guardian(), GUARDIAN);
    }

    function test_revertsOfTheTargetComeThrough() public {
        bytes memory data = abi.encodeCall(factory.setProtocolReserves, (address(0)));
        vm.startPrank(OWNER);
        timelock.schedule(address(factory), 0, data, 0, 0, 0);
        vm.expectRevert(ISenzuFactory.SenzuFactory__ZeroAddress.selector);
        timelock.execute(address(factory), 0, data, 0, 0);
        vm.stopPrank();
    }

    /// @dev Handing the timelock over (to the Governor, later): granted through the timelock, then renounced
    function test_handOver() public {
        address next = address(0xBEEF);
        bytes32[3] memory roles = [timelock.PROPOSER_ROLE(), timelock.EXECUTOR_ROLE(), timelock.CANCELLER_ROLE()];
        for (uint256 i; i < 3; ++i) {
            _run(address(timelock), abi.encodeCall(timelock.grantRole, (roles[i], next)));
        }
        for (uint256 i; i < 3; ++i) {
            vm.prank(OWNER);
            timelock.renounceRole(roles[i], OWNER);
        }

        vm.startPrank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OWNER, timelock.PROPOSER_ROLE()
            )
        );
        timelock.schedule(address(factory), 0, _setGuardian(OWNER), 0, 0, 0);
        vm.stopPrank();

        vm.startPrank(next);
        Timelocked.execute(timelock, address(factory), _setGuardian(next));
        vm.stopPrank();
        assertEq(factory.guardian(), next);
    }
}
