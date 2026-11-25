// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FeeCheckpoint, WAD} from "./Types.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

library FeeLogic {
    using SafeCastLib for uint256;

    uint256 internal constant Q128 = 1 << 128;

    function pending(FeeCheckpoint memory cp, uint256 balance, uint256 feeGrowth0X128, uint256 feeGrowth1X128)
        internal
        pure
        returns (uint256 owed0, uint256 owed1)
    {
        uint256 delta0;
        uint256 delta1;
        // Fee growth is allowed to overflow, as in Uniswap
        unchecked {
            delta0 = feeGrowth0X128 - cp.feeGrowthInside0X128;
            delta1 = feeGrowth1X128 - cp.feeGrowthInside1X128;
        }
        owed0 = cp.owed0 + FullMath.mulDiv(balance, delta0, Q128);
        owed1 = cp.owed1 + FullMath.mulDiv(balance, delta1, Q128);
    }

    function checkpoint(FeeCheckpoint storage cp, uint256 balance, uint256 feeGrowth0X128, uint256 feeGrowth1X128)
        internal
    {
        if (balance != 0) {
            (uint256 owed0, uint256 owed1) = pending(cp, balance, feeGrowth0X128, feeGrowth1X128);
            cp.owed0 = owed0.toUint128();
            cp.owed1 = owed1.toUint128();
        }
        cp.feeGrowthInside0X128 = feeGrowth0X128;
        cp.feeGrowthInside1X128 = feeGrowth1X128;
    }

    /// @dev The bookmark of `held + units` units, `held` of them at `heldMark` and `units` at `movedMark`, both at or
    ///      under `growthX128`: rounded so the units are never credited more than their two bookmarks would credit
    ///      them. `units` is never 0. Fee growth wraps, as in Uniswap, so the marks are compared by their distance
    ///      to `growthX128`
    function mergeMark(uint256 heldMark, uint256 movedMark, uint256 held, uint256 units, uint256 growthX128)
        internal
        pure
        returns (uint256)
    {
        uint256 total = held + units;
        unchecked {
            uint256 heldGap = growthX128 - heldMark;
            uint256 movedGap = growthX128 - movedMark;
            uint256 gap = movedGap >= heldGap
                ? heldGap + FullMath.mulDiv(units, movedGap - heldGap, total)
                : heldGap - FullMath.mulDivRoundingUp(units, heldGap - movedGap, total);
            return growthX128 - gap;
        }
    }

    /// @dev The protocol's cut of `amount` at `cutWad`, rounded down: a holder is never charged more than the rate
    function cut(uint256 amount, uint256 cutWad) internal pure returns (uint256) {
        return FullMath.mulDiv(amount, cutWad, WAD);
    }
}
