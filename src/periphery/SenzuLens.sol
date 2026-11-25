// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuCollateral} from "../interfaces/ISenzuCollateral.sol";
import {ISenzuLens} from "../interfaces/ISenzuLens.sol";
import {ISenzuOracle} from "../interfaces/ISenzuOracle.sol";
import {ISenzuRangeAdapter} from "../interfaces/ISenzuRangeAdapter.sol";
import {ISenzuRiskConfig} from "../interfaces/ISenzuRiskConfig.sol";
import {HealthLogic} from "../libraries/HealthLogic.sol";
import {HealthMath} from "../libraries/HealthMath.sol";
import {RangeAmounts} from "../libraries/RangeAmounts.sol";
import {
    CollateralInput,
    DebtInput,
    DebtTie,
    HealthResult,
    Holdings,
    Market,
    Shape,
    WAD,
    lenderId
} from "../libraries/Types.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 *  @title  SenzuLens
 *  @author Senzu
 *  @notice View-only aggregator for one deployment's frontend; eth_call only. Health matches
 *          `SenzuCollateral.health`, valued by the adapter's `amountsAt` as the core values it. Liquidation prices are
 *          searched within 1/1000x to 1000x of the current price and exact to 1e-6 relative. A closed market reads at
 *          its feed's last answer, flagged `stale`. A position's range fields (`sqrtPaX96`, `sqrtPbX96`, `inRange`,
 *          `liquidity`) are filled for range adapters (ISenzuRangeAdapter) only.
 */
contract SenzuLens is ISenzuLens {
    using SafeCastLib for uint256;
    using SafeCastLib for int256;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    uint256 internal constant SEARCH_RANGE = 1000;

    uint256 internal constant TOLERANCE = 1e12;

    /// @dev What the lens values: an opened position's `units` (`id` != 0, by its adapter's `amountsAt`), or, for a
    ///      preview, `liquidity` between `sqrtPaX96` and `sqrtPbX96` not opened yet (`id` 0)
    struct Valuation {
        uint256 id;
        uint256 units;
        uint160 sqrtPaX96;
        uint160 sqrtPbX96;
        uint128 liquidity;
    }

    /// @inheritdoc ISenzuLens
    address public immutable override collateral;

    /// @inheritdoc ISenzuLens
    address public immutable override borrowable;

    ISenzuOracle internal immutable _oracle;
    ISenzuRiskConfig internal immutable _risk;
    ISenzuAdapter internal immutable _adapter;

    constructor(address collateral_) {
        collateral = collateral_;
        borrowable = address(ISenzuCollateral(collateral_).borrowable());
        _oracle = ISenzuOracle(ISenzuCollateral(collateral_).oracle());
        _risk = ISenzuRiskConfig(ISenzuCollateral(collateral_).riskConfig());
        _adapter = ISenzuAdapter(ISenzuCollateral(collateral_).adapter());
    }

    /// @inheritdoc ISenzuLens
    function getMarkets() external view override returns (MarketView[] memory markets) {
        ISenzuBorrowable b = ISenzuBorrowable(borrowable);
        markets = new MarketView[](b.marketsLength());
        for (uint256 i; i < markets.length; ++i) {
            markets[i] = getMarket(b.marketAt(i));
        }
    }

    /// @inheritdoc ISenzuLens
    function getMarket(address asset) public view override returns (MarketView memory m) {
        ISenzuBorrowable b = ISenzuBorrowable(borrowable);
        Market memory market = b.getMarket(asset);
        m.asset = asset;
        (m.priceWad, m.decimals, m.stale) = price(asset);
        uint256 borrowRate;
        uint256 supplyRate;
        uint256 rateAtTarget;
        (m.supplyAssets, m.borrowAssets, m.utilizationWad, borrowRate, supplyRate, rateAtTarget) = b.marketState(asset);
        m.borrowShares = market.totalBorrowShares;
        m.cash = m.supplyAssets - m.borrowAssets;
        m.borrowAprWad = borrowRate * SECONDS_PER_YEAR;
        m.supplyAprWad = supplyRate * SECONDS_PER_YEAR;
        m.rateAtTargetAprWad = rateAtTarget * SECONDS_PER_YEAR;
        m.reserveFactorWad = market.reserveFactorWad;
    }

    /// @inheritdoc ISenzuLens
    function getLender(address account) external view override returns (LenderView[] memory lender) {
        ISenzuBorrowable b = ISenzuBorrowable(borrowable);
        uint256 n = b.marketsLength();
        LenderView[] memory all = new LenderView[](n);
        uint256 k;
        for (uint256 i; i < n; ++i) {
            address asset = b.marketAt(i);
            uint256 shares = b.balanceOf(account, lenderId(asset));
            if (shares == 0) continue;
            (uint256 priceWad, uint8 decimals,) = price(asset);
            uint256 assets = b.convertToAssets(asset, shares);
            all[k++] = LenderView({
                asset: asset,
                shares: shares,
                assets: assets,
                valueUsdWad: FixedPointMathLib.fullMulDiv(assets, priceWad, 10 ** decimals),
                maxWithdraw: b.maxWithdraw(asset, account)
            });
        }
        lender = new LenderView[](k);
        for (uint256 i; i < k; ++i) {
            lender[i] = all[i];
        }
    }

    /// @inheritdoc ISenzuLens
    function getPair(address token0, address token1) external view override returns (PairView memory p) {
        p.pairKey = keccak256(abi.encode(address(_adapter), token0, token1));
        p.enabled = _risk.pairEnabled(p.pairKey);
        p.token0 = token0;
        p.token1 = token1;
        CollateralInput memory input;
        (input, p.penaltyWad) = _pairInput(token0, token1);
        (p.price0Wad, p.price1Wad) = (input.price0Wad, input.price1Wad);
        p.oracleSqrtPriceX96 = _oracleSqrtPrice(input);
        (p.sigma0Wad, p.sigma1Wad) = (input.sigma0Wad, input.sigma1Wad);
        (,, p.stale0) = price(token0);
        (,, p.stale1) = price(token1);
    }

    /// @inheritdoc ISenzuLens
    function getPositions(address account, uint256[] calldata ids)
        external
        view
        override
        returns (PositionView[] memory positions)
    {
        positions = new PositionView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            positions[i] = getPosition(account, ids[i]);
        }
    }

    /// @inheritdoc ISenzuLens
    function getPosition(address account, uint256 id) public view override returns (PositionView memory v) {
        ISenzuCollateral c = ISenzuCollateral(collateral);
        v.account = account;
        v.id = id;
        if (!_exists(id)) return v;
        v.adapter = address(_adapter);

        (
            CollateralInput memory input,
            Holdings memory holdings,
            DebtInput[] memory debtInputs,
            DebtView[] memory debtViews,
            uint256 penalty
        ) = _positionInputs(account, id);
        v.token0 = input.token0;
        v.token1 = input.token1;
        v.pairKey = keccak256(abi.encode(address(_adapter), v.token0, v.token1));
        v.poolSqrtPriceX96 = _adapter.poolSqrtPriceX96(id);
        v.units = c.balanceOf(account, id);
        v.totalUnits = c.totalSupply(id);
        try ISenzuRangeAdapter(address(_adapter)).shape(id) returns (Shape memory shape) {
            v.sqrtPaX96 = shape.sqrtPaX96;
            v.sqrtPbX96 = shape.sqrtPbX96;
            v.inRange = v.poolSqrtPriceX96 >= v.sqrtPaX96 && v.poolSqrtPriceX96 < v.sqrtPbX96;
            v.liquidity = RangeAmounts.liquidityOf(shape, v.units, v.totalUnits);
        } catch {}
        (v.amount0, v.amount1) = (holdings.amounts0[0], holdings.amounts1[0]);

        HealthResult memory h = HealthMath.evaluate(input, holdings, debtInputs, penalty);
        v.collateralUsdWad = h.collateralUsdWad;
        v.debtUsdWad = h.debtUsdWad;
        v.marginUsdWad = h.collateralUsdWad.toInt256() - h.debtUsdWad.toInt256();
        v.healthWad = h.healthWad;
        v.penaltyWad = penalty;
        (v.feesOwed0, v.feesOwed1) = _adapter.feesOwed(account, id);
        v.liquidation = _liquidationPrices(_ofUnits(id, v.units), input, debtInputs, penalty);
        v.debts = debtViews;
        v.stale = _stale(v.token0) || _stale(v.token1);
        for (uint256 i; i < debtViews.length; ++i) {
            v.stale = v.stale || _stale(debtViews[i].asset);
        }
    }

    /// @inheritdoc ISenzuLens
    function price(address token) public view override returns (uint256 priceWad, uint8 decimals, bool stale) {
        try _oracle.priceWithDecimals(token) returns (uint256 oraclePrice, uint8 tokenDecimals) {
            return (oraclePrice, tokenDecimals, false);
        } catch (bytes memory reason) {
            (priceWad, decimals) = _lastAnswer(token, reason);
            stale = true;
        }
    }

    /// @inheritdoc ISenzuLens
    function priceWithDecimals(address token) external view override returns (uint256 priceWad, uint8 decimals) {
        (priceWad, decimals,) = price(token);
    }

    /// @inheritdoc ISenzuLens
    function pricesWithDecimals(address token0, address token1)
        external
        view
        override
        returns (uint256 price0Wad, uint8 decimals0, uint256 price1Wad, uint8 decimals1)
    {
        (price0Wad, decimals0,) = price(token0);
        (price1Wad, decimals1,) = price(token1);
    }

    /// @dev The oracle's price from the feed's last answer, its age and the token's pause unchecked; any refusal but
    ///      those reverts with the oracle's reason
    function _lastAnswer(address token, bytes memory reason) internal view returns (uint256 priceWad, uint8 decimals) {
        // forge-lint: disable-next-line(unsafe-typecast) the error's selector: its first 4 bytes
        bytes4 refusal = bytes4(reason);
        if (
            refusal != ISenzuOracle.SenzuOracle__StalePrice.selector
                && refusal != ISenzuOracle.SenzuOracle__PricePaused.selector
        ) _revertWith(reason);
        address aggregator;
        (aggregator,, decimals) = _oracle.feedOf(token);
        priceWad = _answerWad(aggregator, reason);
        (address ratio,) = _oracle.ratioFeedOf(token);
        if (ratio != address(0)) priceWad = FixedPointMathLib.fullMulDiv(priceWad, _answerWad(ratio, reason), WAD);
    }

    function _answerWad(address aggregator, bytes memory reason) internal view returns (uint256) {
        (, int256 answer,,,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (answer <= 0) _revertWith(reason);
        return answer.toUint256() * 10 ** (18 - AggregatorV3Interface(aggregator).decimals());
    }

    function _stale(address token) internal view returns (bool stale) {
        (,, stale) = price(token);
    }

    function _revertWith(bytes memory reason) internal pure {
        assembly ("memory-safe") {
            revert(add(reason, 32), mload(reason))
        }
    }

    function _exists(uint256 id) internal view returns (bool) {
        return id != 0 && id < ISenzuCollateral(collateral).nextPositionId();
    }

    function _modules() internal view returns (HealthLogic.Modules memory) {
        return HealthLogic.Modules({
            oracle: _priceSource(), riskConfig: address(_risk), borrowable: borrowable, adapter: address(_adapter)
        });
    }

    /// @dev Where the health math reads prices: this lens, so a closed market reads at its last answer
    function _priceSource() internal view virtual returns (address) {
        return address(this);
    }

    /// @dev The core's own inputs (`HealthLogic.position`), plus a view of each debt
    function _positionInputs(address account, uint256 id)
        internal
        view
        returns (
            CollateralInput memory input,
            Holdings memory holdings,
            DebtInput[] memory debts,
            DebtView[] memory views,
            uint256 penaltyWad
        )
    {
        HealthLogic.Position memory p = HealthLogic.position(
            _modules(),
            account,
            id,
            ISenzuCollateral(collateral).balanceOf(account, id),
            ISenzuCollateral(collateral).totalSupply(id)
        );
        (input, holdings, debts, penaltyWad) = (p.collateral, p.holdings, p.debtInputs, p.penaltyWad);
        views = new DebtView[](p.debts.length);
        for (uint256 i; i < p.debts.length; ++i) {
            (,,, uint256 rate,,) = ISenzuBorrowable(borrowable).marketState(p.debts[i].asset);
            views[i] = DebtView({
                asset: p.debts[i].asset,
                assets: p.debts[i].amount,
                valueUsdWad: debts[i].valueUsdWad,
                borrowAprWad: rate * SECONDS_PER_YEAR
            });
        }
    }

    function _pairInput(address token0, address token1) internal view returns (CollateralInput memory, uint256) {
        return HealthLogic.pairInput(_modules(), token0, token1);
    }

    function _ofUnits(uint256 id, uint256 units) internal pure returns (Valuation memory val) {
        (val.id, val.units) = (id, units);
    }

    function _ofRange(uint160 sqrtPaX96, uint160 sqrtPbX96, uint128 liquidity)
        internal
        pure
        returns (Valuation memory val)
    {
        (val.sqrtPaX96, val.sqrtPbX96, val.liquidity) = (sqrtPaX96, sqrtPbX96, liquidity);
    }

    /// @dev What `val` holds at each price a health check of `input` values it at
    function _holdings(Valuation memory val, CollateralInput memory input) internal view returns (Holdings memory) {
        if (val.id != 0) {
            return HealthLogic.holdings(
                address(_adapter), val.id, val.units, ISenzuCollateral(collateral).totalSupply(val.id), input
            );
        }
        return RangeAmounts.at(val.sqrtPaX96, val.sqrtPbX96, val.liquidity, HealthMath.sqrtPrices(input));
    }

    function _evaluate(Valuation memory val, CollateralInput memory input, DebtInput[] memory debts, uint256 penaltyWad)
        internal
        view
        returns (HealthResult memory)
    {
        return HealthMath.evaluate(input, _holdings(val, input), debts, penaltyWad);
    }

    function _newDebt(CollateralInput memory input, address asset, uint256 amount)
        internal
        view
        returns (DebtInput memory debt, uint256 penaltyWad, bool liquid)
    {
        // No pair penalty: the asset's own for a debt outside the pair, else 0; callers take the max with the pair's
        HealthLogic.Debt memory priced;
        (priced, debt, liquid) = HealthLogic.debtInput(_modules(), asset, amount, input, 0);
        penaltyWad = priced.penaltyWad;
    }

    function _liquidationPrices(
        Valuation memory val,
        CollateralInput memory input,
        DebtInput[] memory debts,
        uint256 penalty
    ) internal view returns (LiquidationPrices memory liq) {
        bool moveToken1 = input.sigma1Wad >= input.sigma0Wad;
        uint256 movedPrice = moveToken1 ? input.price1Wad : input.price0Wad;
        liq.token = moveToken1 ? input.token1 : input.token0;
        if (debts.length == 0 || (val.id != 0 ? val.units == 0 : val.liquidity == 0)) return liq;

        if (_surplusAt(val, input, debts, penalty, moveToken1, WAD) < 0) {
            (liq.lowerWad, liq.upperWad) = (movedPrice, movedPrice);
            return liq;
        }
        uint256 kMin = WAD / SEARCH_RANGE;
        uint256 kMax = WAD * SEARCH_RANGE;
        if (_surplusAt(val, input, debts, penalty, moveToken1, kMin) < 0) {
            liq.lowerWad = FixedPointMathLib.fullMulDiv(
                movedPrice, _bisectPrice(val, input, debts, penalty, moveToken1, kMin, WAD), WAD
            );
        }
        if (_surplusAt(val, input, debts, penalty, moveToken1, kMax) < 0) {
            liq.upperWad = FixedPointMathLib.fullMulDiv(
                movedPrice, _bisectPrice(val, input, debts, penalty, moveToken1, kMax, WAD), WAD
            );
        }
    }

    function _bisectPrice(
        Valuation memory val,
        CollateralInput memory input,
        DebtInput[] memory debts,
        uint256 penalty,
        bool moveToken1,
        uint256 unsafeK,
        uint256 safeK
    ) internal view returns (uint256) {
        while (true) {
            (uint256 lo, uint256 hi) = unsafeK < safeK ? (unsafeK, safeK) : (safeK, unsafeK);
            if ((hi - lo) * WAD <= lo * TOLERANCE) return unsafeK;
            uint256 mid = FixedPointMathLib.sqrt(lo * hi);
            if (_surplusAt(val, input, debts, penalty, moveToken1, mid) >= 0) safeK = mid;
            else unsafeK = mid;
        }
        return unsafeK;
    }

    function _surplusAt(
        Valuation memory val,
        CollateralInput memory input,
        DebtInput[] memory debts,
        uint256 penalty,
        bool moveToken1,
        uint256 k
    ) internal view returns (int256 surplus) {
        uint256 original = moveToken1 ? input.price1Wad : input.price0Wad;
        uint256 moved = FixedPointMathLib.fullMulDiv(original, k, WAD);
        if (moved == 0) moved = 1;
        if (moveToken1) input.price1Wad = moved;
        else input.price0Wad = moved;

        DebtTie movingTie = moveToken1 ? DebtTie.Token1 : DebtTie.Token0;
        DebtInput[] memory scaled = new DebtInput[](debts.length);
        for (uint256 i; i < debts.length; ++i) {
            scaled[i] = DebtInput({
                valueUsdWad: debts[i].tie == movingTie
                    ? FixedPointMathLib.fullMulDivUp(debts[i].valueUsdWad, k, WAD)
                    : debts[i].valueUsdWad,
                sigmaWad: debts[i].sigmaWad,
                tie: debts[i].tie
            });
        }
        surplus = _evaluate(val, input, scaled, penalty).minSurplusUsdWad;

        if (moveToken1) input.price1Wad = original;
        else input.price0Wad = original;
    }

    function _oracleSqrtPrice(CollateralInput memory input) internal pure returns (uint160) {
        return HealthMath.sqrtPriceX96FromUsd(input.price0Wad, input.price1Wad, input.decimals0, input.decimals1);
    }

    function _max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }
}
