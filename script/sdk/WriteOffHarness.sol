// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SenzuBorrowable} from "../../src/core/SenzuBorrowable.sol";
import {BorrowLogic} from "../../src/libraries/BorrowLogic.sol";
import {DebtLanes} from "../../src/libraries/DebtLanes.sol";
import {Market} from "../../src/libraries/Types.sol";
import {DebtLane} from "../../src/types/DebtLane.sol";

/**
 *  @title  WriteOffHarness
 *  @notice SenzuBorrowable unchanged, plus entry points that set a market and a position and run the real
 *          `_writeOff` or `_bookRepay` on them, for the vectors. Its wiring is all zero: at zero elapsed time neither
 *          calls another contract. Never deployed; only run by `script/SdkVectors.s.sol`.
 */
contract WriteOffHarness is SenzuBorrowable {
    address internal constant ASSET = address(0x12);
    uint256 internal constant POSITION = 1;

    /// @return next The market after the write-off
    /// @return left The position's borrow shares after it
    function runWriteOff(Market memory market, uint256 debtShares) external returns (Market memory next, uint256 left) {
        _setPosition(market, debtShares);
        _writeOff(ASSET, address(this), POSITION);

        return ($.markets[ASSET], BorrowLogic.sharesOf($, $.markets[ASSET], address(this), POSITION));
    }

    /// @return repaid What the repayment takes from the payer
    /// @return next The market after it
    /// @return left The position's borrow shares after it
    function runRepay(Market memory market, uint256 debtShares, uint256 assets)
        external
        returns (uint256 repaid, Market memory next, uint256 left)
    {
        _setPosition(market, debtShares);
        (, repaid) = _bookRepay(address(this), POSITION, ASSET, assets);
        return (repaid, $.markets[ASSET], BorrowLogic.sharesOf($, $.markets[ASSET], address(this), POSITION));
    }

    function _setPosition(Market memory market, uint256 debtShares) internal {
        market.exists = true;
        market.lastAccrual = uint64(block.timestamp);
        $.markets[ASSET] = market;
        $.debts[address(this)][POSITION] = DebtLane.unwrap(DebtLanes.lane(market.index, debtShares));
    }
}

/// @notice Deploys the harness, answering its constructor's `parameters()` with zero wiring
contract WriteOffHarnessDeployer {
    function parameters() external pure returns (address, address, address, address, address) {}

    function deploy() external returns (WriteOffHarness) {
        return new WriteOffHarness();
    }
}
