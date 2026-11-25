// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {HealthLogic} from "./HealthLogic.sol";
import {HealthResult, MIN_INCENTIVE, WAD} from "./Types.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";

library LiquidationLogic {
    function liquidate(
        HealthLogic.Modules memory modules,
        address borrower,
        uint256 id,
        address asset,
        uint256 maxRepayAssets,
        uint256 units,
        uint256 totalUnits
    ) internal view returns (uint256 seizedUnits, uint256 repayAssets, uint256 feeAssets) {
        HealthLogic.Position memory p = HealthLogic.position(modules, borrower, id, units, totalUnits);
        HealthResult memory health = HealthLogic.evaluate(p);
        if (health.minSurplusUsdWad >= 0) revert ISenzuCollateral.SenzuCollateral__NotLiquidatable();
        uint256 feeWad = ISenzuRiskConfig(modules.riskConfig).liquidationFeeWad(modules.adapter);
        return seizeFor(health, _find(p.debts, asset), maxRepayAssets, units, feeWad, _hasOtherDebt(p.debts, asset));
    }

    /// @notice What a liquidation of a liquidatable position takes for repaying `debt`, up to `maxRepayAssets`
    function seizeFor(
        HealthResult memory health,
        HealthLogic.Debt memory debt,
        uint256 maxRepayAssets,
        uint256 units,
        uint256 feeWad,
        bool hasOtherDebt
    ) internal pure returns (uint256 seizedUnits, uint256 repayAssets, uint256 feeAssets) {
        if (health.collateralUsdWad == 0) revert ISenzuCollateral.SenzuCollateral__ZeroAmount();
        if (debt.amount == 0) revert ISenzuCollateral.SenzuCollateral__NoDebt();

        repayAssets = maxRepayAssets < debt.amount ? maxRepayAssets : debt.amount;
        if (repayAssets == 0) revert ISenzuCollateral.SenzuCollateral__ZeroAmount();

        // Repay assets in USD + liquidator incentive
        uint256 scale = 10 ** debt.decimals;
        uint256 penalty = _bearable(health, debt.penaltyWad);
        uint256 repayUsd = FixedPointMathLib.fullMulDiv(repayAssets, debt.priceWad, scale);
        uint256 seizeUsd = FixedPointMathLib.fullMulDiv(repayUsd, penalty, WAD);

        if (seizeUsd >= health.collateralUsdWad) {
            // Take every unit, and repay only what the collateral covers, rounded up
            seizedUnits = units;

            uint256 coverableUsd = FixedPointMathLib.fullMulDivUp(health.collateralUsdWad, WAD, MIN_INCENTIVE);
            uint256 coverable = FixedPointMathLib.fullMulDivUp(coverableUsd, scale, debt.priceWad);
            if (coverable < repayAssets) repayAssets = coverable;
        } else {
            // Take the units worth `seizeUsd`, rounded down
            seizedUnits = FixedPointMathLib.fullMulDiv(units, seizeUsd, health.collateralUsdWad);
        }

        // The protocol's fee is a share of the liquidator's gain
        if (feeWad == 0 || seizedUnits == 0) return (seizedUnits, repayAssets, 0);

        // No fee on bad debt
        bool underwater = FixedPointMathLib.fullMulDiv(health.collateralUsdWad, WAD, MIN_INCENTIVE) < health.debtUsdWad;
        bool leavesDebt = seizedUnits == units && (repayAssets < debt.amount || hasOtherDebt);
        if (underwater || leavesDebt) return (seizedUnits, repayAssets, 0);

        // What was taken minus what was repaid
        uint256 seizedUsd = FixedPointMathLib.fullMulDiv(health.collateralUsdWad, seizedUnits, units);
        uint256 seizedAssets = FixedPointMathLib.fullMulDiv(seizedUsd, scale, debt.priceWad);

        if (seizedAssets > repayAssets) {
            feeAssets = FixedPointMathLib.fullMulDiv(seizedAssets - repayAssets, feeWad, WAD);
        }
    }

    /// @dev An empty debt when the position doesn't owe `asset`
    function _find(HealthLogic.Debt[] memory debts, address asset) private pure returns (HealthLogic.Debt memory debt) {
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].asset == asset) return debts[i];
        }
    }

    function _hasOtherDebt(HealthLogic.Debt[] memory debts, address asset) private pure returns (bool) {
        for (uint256 i; i < debts.length; ++i) {
            if (debts[i].asset != asset && debts[i].amount > 0) return true;
        }
        return false;
    }

    /// @dev The penalty shrinks to the position's collateral / debt, down to MIN_INCENTIVE
    function _bearable(HealthResult memory health, uint256 penaltyWad) private pure returns (uint256) {
        if (health.debtUsdWad == 0) return penaltyWad;
        uint256 ratio = FixedPointMathLib.fullMulDiv(health.collateralUsdWad, WAD, health.debtUsdWad);
        if (ratio >= penaltyWad) return penaltyWad;
        return ratio < MIN_INCENTIVE ? MIN_INCENTIVE : ratio;
    }
}
