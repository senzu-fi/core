// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @notice Admin calls through the factory admin, OpenZeppelin's TimelockController, while its delay is 0 (before
///         launch): scheduled and executed in one go. Once a delay is set, schedule the calls and execute them later
library Timelocked {
    function execute(TimelockController timelock, address target, bytes memory data) internal {
        require(timelock.getMinDelay() == 0, "the timelock has a delay: schedule these calls, execute them later");
        // An executed operation stays done forever, so the same call again needs a salt not used yet
        bytes32 salt;
        while (timelock.isOperation(timelock.hashOperation(target, 0, data, bytes32(0), salt))) {
            salt = bytes32(uint256(salt) + 1);
        }
        timelock.schedule(target, 0, data, bytes32(0), salt, 0);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }
}
