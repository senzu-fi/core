// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {HealthMath} from "./HealthMath.sol";
import {CollateralInput, DebtInput, DebtTie, HealthResult, Holdings, TokenRisk} from "./Types.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {ISenzuOracle} from "../interfaces/ISenzuOracle.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";

library HealthLogic {
    struct Modules {
        address oracle;
        address riskConfig;
        address borrowable;
        address adapter;
    }

    /// @param penaltyWad Its liquidation's penalty: the pair's, or the asset's own when higher (repaying a debt outside
    ///        the pair, a liquidator sells the pair's tokens and buys the asset)
    struct Debt {
        address asset;
        uint256 amount;
        uint256 priceWad;
        uint8 decimals;
        uint256 penaltyWad;
    }

    struct Position {
        CollateralInput collateral;
        /// @dev Cached decimal scales and stressed prices from `HealthMath.stressed(collateral)`
        HealthMath.Stressed stressed;
        /// @dev What the account's units hold at `HealthMath.sqrtPrices(collateral)`, from the adapter
        Holdings holdings;
        Debt[] debts;
        /// @dev The same debts as HealthMath reads them
        DebtInput[] debtInputs;
        /// @dev The highest of the debts' penalties, the pair's with no debt: the health check's
        uint256 penaltyWad;
        /// @dev A debt outside the pair whose token isn't `liquid` (zero if none)
        address illiquidDebt;
    }

    /// @dev Debts as the borrowable's `debts(account, id)` returns them now
    function requireHealthy(
        Modules memory modules,
        uint256 id,
        uint256 units,
        uint256 totalUnits,
        address asset0,
        uint256 amount0,
        address asset1,
        uint256 amount1
    ) internal view {
        Position memory p = _position(modules, id, units, totalUnits, asset0, amount0, asset1, amount1);
        if (p.illiquidDebt != address(0)) {
            revert ISenzuCollateral.SenzuCollateral__IlliquidDebtOutsideItsPair(p.illiquidDebt);
        }
        if (evaluate(p).minSurplusUsdWad < 0) revert ISenzuCollateral.SenzuCollateral__InsufficientCollateral();
    }

    function evaluate(Position memory p) internal pure returns (HealthResult memory) {
        return HealthMath.evaluate(p.collateral, p.holdings, p.debtInputs, p.penaltyWad, p.stressed);
    }

    /// @notice Position `id` as `account`'s `units` back it, at oracle prices. The position must exist; the lens and
    ///         previews read positions through this same function
    function position(Modules memory modules, address account, uint256 id, uint256 units, uint256 totalUnits)
        internal
        view
        returns (Position memory)
    {
        (address asset0, uint256 amount0, address asset1, uint256 amount1) =
            ISenzuBorrowable(modules.borrowable).debts(account, id);
        return _position(modules, id, units, totalUnits, asset0, amount0, asset1, amount1);
    }

    /// @notice What `units` of position `id` hold at each price a health check values `collateral` at, from the
    ///         adapter (none for no units)
    function holdings(address adapter, uint256 id, uint256 units, uint256 totalUnits, CollateralInput memory collateral)
        internal
        view
        returns (Holdings memory)
    {
        return _holdings(adapter, id, units, totalUnits, collateral, HealthMath.stressed(collateral));
    }

    function _holdings(
        address adapter,
        uint256 id,
        uint256 units,
        uint256 totalUnits,
        CollateralInput memory collateral,
        HealthMath.Stressed memory s
    ) private view returns (Holdings memory h) {
        if (units == 0) return h;
        uint160[5] memory prices = HealthMath.sqrtPrices(collateral, s);
        (h.amounts0, h.amounts1) = ISenzuAdapter(adapter).amountsAt(id, units, totalUnits, prices);
    }

    function _position(
        Modules memory modules,
        uint256 id,
        uint256 units,
        uint256 totalUnits,
        address asset0,
        uint256 amount0,
        address asset1,
        uint256 amount1
    ) private view returns (Position memory p) {
        (address token0, address token1) = ISenzuAdapter(modules.adapter).tokens(id);
        uint256 pairPenaltyWad;
        (p.collateral, pairPenaltyWad) = pairInput(modules, token0, token1);
        p.stressed = HealthMath.stressed(p.collateral);
        p.holdings = _holdings(modules.adapter, id, units, totalUnits, p.collateral, p.stressed);
        p.penaltyWad = pairPenaltyWad;

        if (asset0 == address(0)) return p;
        uint256 n = asset1 == address(0) ? 1 : 2;
        p.debts = new Debt[](n);
        p.debtInputs = new DebtInput[](n);
        _addDebt(modules, p, 0, asset0, amount0, pairPenaltyWad);
        if (n == 2) _addDebt(modules, p, 1, asset1, amount1, pairPenaltyWad);
    }

    function _addDebt(
        Modules memory modules,
        Position memory p,
        uint256 i,
        address asset,
        uint256 amount,
        uint256 pairPenaltyWad
    ) private view {
        bool liquid;
        (p.debts[i], p.debtInputs[i], liquid) = debtInput(modules, asset, amount, p.collateral, pairPenaltyWad);
        if (p.debts[i].penaltyWad > p.penaltyWad) p.penaltyWad = p.debts[i].penaltyWad;
        if (!liquid && p.illiquidDebt == address(0)) p.illiquidDebt = asset;
    }

    /// @notice The pair at oracle prices, and its penalty (the higher of its two tokens')
    function pairInput(Modules memory modules, address token0, address token1)
        internal
        view
        returns (CollateralInput memory collateral, uint256 pairPenaltyWad)
    {
        collateral.token0 = token0;
        collateral.token1 = token1;
        (collateral.price0Wad, collateral.decimals0, collateral.price1Wad, collateral.decimals1) =
            ISenzuOracle(modules.oracle).pricesWithDecimals(token0, token1);
        (collateral.sigma0Wad, collateral.sigma1Wad, pairPenaltyWad) =
            ISenzuRiskConfig(modules.riskConfig).pairRisk(modules.adapter, token0, token1);
    }

    /// @notice `amount` of `asset` owed against `collateral`: the debt at the asset's price (USD per whole token,
    ///         1e18) and as HealthMath reads it, in USD rounded up. `debt.penaltyWad` is `pairPenaltyWad`, or the
    ///         asset's own when higher (a debt outside the pair); `liquid` is true for a pair token, the asset's flag
    ///         otherwise
    function debtInput(
        Modules memory modules,
        address asset,
        uint256 amount,
        CollateralInput memory collateral,
        uint256 pairPenaltyWad
    ) internal view returns (Debt memory debt, DebtInput memory input, bool liquid) {
        (debt.asset, debt.amount, debt.penaltyWad, liquid) = (asset, amount, pairPenaltyWad, true);
        if (asset == collateral.token0) {
            (input.tie, debt.priceWad, debt.decimals, input.sigmaWad) =
            (DebtTie.Token0, collateral.price0Wad, collateral.decimals0, collateral.sigma0Wad);
        } else if (asset == collateral.token1) {
            (input.tie, debt.priceWad, debt.decimals, input.sigmaWad) =
            (DebtTie.Token1, collateral.price1Wad, collateral.decimals1, collateral.sigma1Wad);
        } else {
            (debt.priceWad, debt.decimals) = ISenzuOracle(modules.oracle).priceWithDecimals(asset);
            TokenRisk memory risk = ISenzuRiskConfig(modules.riskConfig).tokenRisk(modules.adapter, asset);
            (input.sigmaWad, liquid) = (risk.sigmaWad, risk.liquid);
            if (risk.penaltyWad > pairPenaltyWad) debt.penaltyWad = risk.penaltyWad;
        }
        input.valueUsdWad = FixedPointMathLib.fullMulDivUp(amount, debt.priceWad, 10 ** debt.decimals);
    }
}
