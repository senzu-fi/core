// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuCollateral} from "../../src/interfaces/ISenzuCollateral.sol";
import {ISenzuLockCallback} from "../../src/interfaces/ISenzuLockCallback.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {Vm} from "forge-std/Vm.sol";

Vm constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @dev Liquidation with the caller's own funds, as `liquidate` worked outside a lock: the repayment leaves the caller's
///      wallet (moved with `deal`, since a test's prank can't be overridden inside) and is settled in the same lock.
///      Stateless, so one copy serves every deployment
contract LockLiquidator is ISenzuLockCallback, StdCheats {
    function liquidate(
        ISenzuCollateral collateral,
        address borrower,
        uint256 id,
        address asset,
        uint256 repayAssets,
        address receiver
    ) external returns (uint256 seizedUnits, uint256 repaid) {
        bytes memory data = abi.encode(msg.sender, borrower, id, asset, repayAssets, receiver);
        (seizedUnits, repaid,) = abi.decode(collateral.lock(data), (uint256, uint256, uint256));
    }

    function liquidateWithFee(
        ISenzuCollateral collateral,
        address borrower,
        uint256 id,
        address asset,
        uint256 repayAssets,
        address receiver
    ) external returns (uint256 seizedUnits, uint256 repaid, uint256 fee) {
        bytes memory data = abi.encode(msg.sender, borrower, id, asset, repayAssets, receiver);
        return abi.decode(collateral.lock(data), (uint256, uint256, uint256));
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        (address payer, address borrower, uint256 id, address asset, uint256 repayAssets, address receiver) =
            abi.decode(data, (address, address, uint256, address, uint256, address));
        ISenzuCollateral collateral = ISenzuCollateral(msg.sender);
        (uint256 seizedUnits, uint256 repaid, uint256 fee) =
            collateral.liquidate(borrower, id, asset, repayAssets, receiver);
        uint256 due = repaid + fee;

        if (IERC20(asset).allowance(payer, address(this)) >= due) {
            require(IERC20(asset).transferFrom(payer, address(this), due), "LockLiquidator: transferFrom failed");
        } else {
            uint256 payerBalance = IERC20(asset).balanceOf(payer);
            require(payerBalance >= due, "LockLiquidator: payer can't pay");
            deal(asset, payer, payerBalance - due);
            deal(asset, address(this), IERC20(asset).balanceOf(address(this)) + due);
        }
        address borrowable = address(collateral.borrowable());
        if (IERC20(asset).allowance(address(this), borrowable) < due) {
            IERC20(asset).approve(borrowable, type(uint256).max);
        }
        collateral.settle(asset, due);
        return abi.encode(seizedUnits, repaid, fee);
    }
}

/// @dev The shared LockLiquidator, placed on first use (a cheatcode, so a pending `vm.prank` still applies to the call)
function lockLiquidator() returns (LockLiquidator liquidator) {
    liquidator = LockLiquidator(address(uint160(uint256(keccak256("senzu.test.lockLiquidator")))));
    if (address(liquidator).code.length == 0) {
        VM.etch(address(liquidator), type(LockLiquidator).runtimeCode);
        VM.allowCheatcodes(address(liquidator));
    }
}
