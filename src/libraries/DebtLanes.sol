// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {DebtLane} from "../types/DebtLane.sol";

/**
 *  @title  DebtLanes
 *  @notice A position's debts: at most two, in any two markets, as two lanes (`DebtLane`) in one slot: lane 0 in the
 *          low 128 bits, lane 1 in the high. Used lanes are always the first ones.
 */
library DebtLanes {
    /// @dev A lane is `shares << 8 | marketIndex`: 119 bits of shares and 8 of index fill `LANE_MASK`'s 127
    uint256 internal constant MAX_SHARES = 1 << 119;

    uint256 private constant LANE_MASK = (1 << 127) - 1;

    function hasDebt(uint256 word) internal pure returns (bool) {
        return word != 0;
    }

    /// @notice Unpacks both lanes onto the stack with no memory allocation
    function parse(uint256 word) internal pure returns (DebtLane l0, DebtLane l1) {
        l0 = DebtLane.wrap(word & LANE_MASK);
        l1 = DebtLane.wrap((word >> 128) & LANE_MASK);
    }

    function sharesOf(uint256 word, uint8 idx) internal pure returns (uint256) {
        (DebtLane l0, DebtLane l1) = parse(word);
        if (l0.isEmpty()) return 0;
        if (l0.marketIndex() == idx) return l0.shares();
        return !l1.isEmpty() && l1.marketIndex() == idx ? l1.shares() : 0;
    }

    /// @notice The used lanes, in order
    function lanes(uint256 word) internal pure returns (DebtLane[] memory list) {
        (DebtLane l0, DebtLane l1) = parse(word);
        if (l0.isEmpty()) return new DebtLane[](0);
        if (l1.isEmpty()) {
            list = new DebtLane[](1);
            list[0] = l0;
        } else {
            list = new DebtLane[](2);
            list[0] = l0;
            list[1] = l1;
        }
    }

    /// @notice Adds `amount` shares to market `idx`'s lane, or takes the free lane if the position owes one market
    function add(uint256 word, uint8 idx, uint256 amount) internal pure returns (uint256) {
        (DebtLane l0, DebtLane l1) = parse(word);
        if (l0.isEmpty() || l0.marketIndex() == idx) return _setLane0(word, lane(idx, l0.shares() + amount));
        if (l1.isEmpty() || l1.marketIndex() == idx) return _setLane1(word, lane(idx, l1.shares() + amount));
        revert ISenzuBorrowable.SenzuBorrowable__TooManyDebts();
    }

    /// @notice Takes `amount` shares off market `idx`'s lane; an emptied lane 0 is filled by lane 1
    function sub(uint256 word, uint8 idx, uint256 amount) internal pure returns (uint256) {
        (DebtLane l0, DebtLane l1) = parse(word);
        if (l0.isEmpty()) revert ISenzuBorrowable.SenzuBorrowable__NoDebt();
        if (l0.marketIndex() == idx) {
            uint256 left0 = l0.shares() - amount;
            return left0 == 0 ? word >> 128 : _setLane0(word, lane(idx, left0));
        }
        if (l1.isEmpty() || l1.marketIndex() != idx) revert ISenzuBorrowable.SenzuBorrowable__NoDebt();
        uint256 left1 = l1.shares() - amount;
        return left1 == 0 ? word & LANE_MASK : _setLane1(word, lane(idx, left1));
    }

    function lane(uint8 idx, uint256 amount) internal pure returns (DebtLane) {
        if (amount >= MAX_SHARES) revert ISenzuBorrowable.SenzuBorrowable__DebtTooLarge();
        return DebtLane.wrap((amount << 8) | idx);
    }

    function _setLane0(uint256 word, DebtLane l) private pure returns (uint256) {
        return (word & ~LANE_MASK) | DebtLane.unwrap(l);
    }

    function _setLane1(uint256 word, DebtLane l) private pure returns (uint256) {
        return (word & LANE_MASK) | (DebtLane.unwrap(l) << 128);
    }
}
