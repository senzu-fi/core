// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BorrowLogic} from "../../src/libraries/BorrowLogic.sol";
import {DebtLanes} from "../../src/libraries/DebtLanes.sol";
import {FeeLogic} from "../../src/libraries/FeeLogic.sol";
import {HealthLogic} from "../../src/libraries/HealthLogic.sol";
import {HealthMath} from "../../src/libraries/HealthMath.sol";
import {LiquidationLogic} from "../../src/libraries/LiquidationLogic.sol";
import {MarketLogic} from "../../src/libraries/MarketLogic.sol";
import {RangeAmounts} from "../../src/libraries/RangeAmounts.sol";
import {
    BorrowableState,
    CollateralInput,
    DebtInput,
    FeeCheckpoint,
    HealthResult,
    Holdings,
    Market,
    Rounding,
    Shape,
    TokenRisk
} from "../../src/libraries/Types.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";
import {DebtLane} from "../../src/types/DebtLane.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice A range position's health inputs, as the vectors draw them: the SDK's `CollateralInput`
struct RangeCollateral {
    Shape shape;
    uint128 accountLiquidity;
    uint256 price0Wad;
    uint256 price1Wad;
    uint8 decimals0;
    uint8 decimals1;
    uint256 sigma0Wad;
    uint256 sigma1Wad;
}

/**
 *  @title  SdkWorld
 *  @notice A whole deployment in one contract for the SDK vectors: it answers the calls SenzuLens and the logic
 *          libraries make to the collateral, borrowable, oracle, risk config and adapter, from state the vector
 *          script sets. It also exposes the internal library functions externally so the script can try/catch
 *          their reverts. Never deployed; only run by `script/SdkVectors.s.sol`.
 */
contract SdkWorld {
    address public constant TOKEN0 = address(0x10);
    address public constant TOKEN1 = address(0x11);
    address public constant OTHER = address(0x12);
    uint256 public constant POSITION = 1;

    struct Token {
        uint256 priceWad;
        uint8 decimals;
        uint64 sigmaWad;
        uint64 penaltyWad;
    }

    mapping(address => Token) internal _tokens;
    Shape internal _shape;
    uint256 internal _units;
    address[] internal _debtAssets;
    uint256[] internal _debtAmounts;
    uint64 internal _borrowFeeWad;
    uint64 internal _liquidationFeeWad;
    uint256 internal _supplyAssets;
    uint256 internal _borrowAssets;
    uint256 internal _borrowShares;
    uint256 internal _accountShares;

    BorrowableState internal _borrowable;
    uint256 internal _nextId;
    FeeCheckpoint internal _checkpoint;

    /*  ================================================
                             Setup
        ================================================  */

    function setToken(address token, uint256 priceWad, uint8 decimals, uint64 sigmaWad) external {
        Token storage t = _tokens[token];
        (t.priceWad, t.decimals, t.sigmaWad) = (priceWad, decimals, sigmaWad);
    }

    function setPenalty(address token, uint64 penaltyWad) external {
        _tokens[token].penaltyWad = penaltyWad;
    }

    function setPosition(uint160 sqrtPa, uint160 sqrtPb, uint128 liquidity, uint256 units) external {
        _shape = Shape(TOKEN0, TOKEN1, sqrtPa, sqrtPb, liquidity);
        _units = units;
    }

    function setDebts(address[] calldata assets, uint256[] calldata amounts) external {
        _debtAssets = assets;
        _debtAmounts = amounts;
    }

    function setBorrowFee(uint64 borrowFeeWad_) external {
        _borrowFeeWad = borrowFeeWad_;
    }

    function setLiquidationFee(uint64 liquidationFeeWad_) external {
        _liquidationFeeWad = liquidationFeeWad_;
    }

    function setMarket(uint256 supplyAssets, uint256 borrowAssets, uint256 borrowShares, uint256 accountShares)
        external
    {
        (_supplyAssets, _borrowAssets, _borrowShares, _accountShares) =
        (supplyAssets, borrowAssets, borrowShares, accountShares);
    }

    /*  ================================================
                         Deployment API
        ================================================  */

    // Collateral
    function borrowable() external view returns (address) {
        return address(this);
    }

    function oracle() external view returns (address) {
        return address(this);
    }

    function riskConfig() external view returns (address) {
        return address(this);
    }

    function adapter() external view returns (address) {
        return address(this);
    }

    /// @dev The lens refuses ids that were never opened; the world's one position is the last one
    function nextPositionId() external pure returns (uint256) {
        return POSITION + 1;
    }

    function totalSupply(uint256) external view returns (uint256) {
        return _units;
    }

    function balanceOf(address, uint256) external view returns (uint256) {
        return _units;
    }

    // Adapter
    function shape(uint256) external view returns (Shape memory) {
        return _shape;
    }

    function tokens(uint256) external view returns (address, address) {
        return (_shape.token0, _shape.token1);
    }

    function amountsAt(uint256, uint256 accountUnits, uint256 totalUnits, uint160[5] calldata sqrtPricesX96)
        external
        view
        returns (uint256[5] memory, uint256[5] memory)
    {
        return RangeAmounts.ofUnits(_shape, accountUnits, totalUnits, sqrtPricesX96);
    }

    // Oracle
    function priceWithDecimals(address token) external view returns (uint256, uint8) {
        return (_tokens[token].priceWad, _tokens[token].decimals);
    }

    function pricesWithDecimals(address token0, address token1) external view returns (uint256, uint8, uint256, uint8) {
        Token memory t0 = _tokens[token0];
        Token memory t1 = _tokens[token1];
        return (t0.priceWad, t0.decimals, t1.priceWad, t1.decimals);
    }

    // Risk config
    function tokenRisk(address, address token) external view returns (TokenRisk memory) {
        return TokenRisk(_tokens[token].sigmaWad, _tokens[token].penaltyWad, true, true);
    }

    function pairRisk(address, address token0, address token1) external view returns (uint256, uint256, uint256) {
        Token memory t0 = _tokens[token0];
        Token memory t1 = _tokens[token1];
        return (t0.sigmaWad, t1.sigmaWad, t0.penaltyWad > t1.penaltyWad ? t0.penaltyWad : t1.penaltyWad);
    }

    function borrowFeeWad(address) external view returns (uint64) {
        return _borrowFeeWad;
    }

    function liquidationFeeWad(address) external view returns (uint64) {
        return _liquidationFeeWad;
    }

    // Borrowable
    function debts(address, uint256) external view returns (address a0, uint256 d0, address a1, uint256 d1) {
        if (_debtAssets.length > 0) (a0, d0) = (_debtAssets[0], _debtAmounts[0]);
        if (_debtAssets.length > 1) (a1, d1) = (_debtAssets[1], _debtAmounts[1]);
    }

    function debtOf(address, uint256, address asset) external view returns (uint256) {
        for (uint256 i; i < _debtAssets.length; ++i) {
            if (_debtAssets[i] == asset) return _debtAmounts[i];
        }
        return 0;
    }

    function marketState(address) external view returns (uint256, uint256, uint256, uint256, uint256, uint256) {
        return (_supplyAssets, _borrowAssets, 0, 0, 0, 0);
    }

    /// @dev One market for every asset: the lens books borrows against its borrow shares
    function getMarket(address) external view returns (Market memory market) {
        market.exists = true;
        market.totalSupplyAssets = uint128(_supplyAssets);
        market.totalBorrowAssets = uint128(_borrowAssets);
        market.totalBorrowShares = uint128(_borrowShares);
    }

    function borrowSharesOf(address, uint256, address) external view returns (uint256) {
        return _accountShares;
    }

    /*  ================================================
                        Library wrappers
        ================================================  */

    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDivRoundingUp(a, b, d);
    }

    function sqrt(uint256 x) external pure returns (uint256) {
        return FixedPointMathLib.sqrt(x);
    }

    function sqrtPriceAtTick(int24 tick) external pure returns (uint160) {
        return TickMath.getSqrtPriceAtTick(tick);
    }

    function tickAtSqrtPrice(uint160 sqrtPrice) external pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sqrtPrice);
    }

    function amount0Delta(uint160 a, uint160 b, uint128 liquidity, bool roundUp) external pure returns (uint256) {
        return SqrtPriceMath.getAmount0Delta(a, b, liquidity, roundUp);
    }

    function amount1Delta(uint160 a, uint160 b, uint128 liquidity, bool roundUp) external pure returns (uint256) {
        return SqrtPriceMath.getAmount1Delta(a, b, liquidity, roundUp);
    }

    function nextSqrtPrice(uint160 sqrtPrice, uint128 liquidity, uint256 amount, bool zeroForOne, bool input)
        external
        pure
        returns (uint160)
    {
        return input
            ? SqrtPriceMath.getNextSqrtPriceFromInput(sqrtPrice, liquidity, amount, zeroForOne)
            : SqrtPriceMath.getNextSqrtPriceFromOutput(sqrtPrice, liquidity, amount, zeroForOne);
    }

    function amountsForLiquidity(uint160 sqrtPrice, uint160 a, uint160 b, uint128 liquidity)
        external
        pure
        returns (uint256, uint256)
    {
        return LiquidityAmounts.getAmountsForLiquidity(sqrtPrice, a, b, liquidity);
    }

    function liquidityForAmounts(uint160 sqrtPrice, uint160 a, uint160 b, uint256 amount0, uint256 amount1)
        external
        pure
        returns (uint128)
    {
        return LiquidityAmounts.getLiquidityForAmounts(sqrtPrice, a, b, amount0, amount1);
    }

    function sqrtPriceFromUsd(uint256 p0, uint256 p1, uint8 d0, uint8 d1) external pure returns (uint160) {
        return HealthMath.sqrtPriceX96FromUsd(p0, p1, d0, d1);
    }

    /// @dev As the core runs it: the range's holdings at the check's prices, then the stress test
    function evaluate(RangeCollateral memory c, DebtInput[] memory debtInputs, uint256 penaltyWad)
        external
        pure
        returns (HealthResult memory)
    {
        CollateralInput memory pair = _pair(c);
        Holdings memory holdings =
            RangeAmounts.at(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity, HealthMath.sqrtPrices(pair));
        return HealthMath.evaluate(pair, holdings, debtInputs, penaltyWad);
    }

    function sqrtPrices(CollateralInput memory pair) external pure returns (uint160[5] memory) {
        return HealthMath.sqrtPrices(pair);
    }

    /// @dev The core's check on what any adapter reports, not only a range's
    function evaluateHoldings(
        CollateralInput memory pair,
        Holdings memory holdings,
        DebtInput[] memory debtInputs,
        uint256 penaltyWad
    ) external pure returns (HealthResult memory) {
        return HealthMath.evaluate(pair, holdings, debtInputs, penaltyWad);
    }

    /// @dev The range's USD value at prices `p0` and `p1`, as the previews value it
    function collateralUsdAt(RangeCollateral memory c, uint256 p0, uint256 p1) external pure returns (uint256) {
        if (c.accountLiquidity == 0) return 0;
        uint160 sqrtPriceX96 = HealthMath.sqrtPriceX96FromUsd(p0, p1, c.decimals0, c.decimals1);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity
        );
        return HealthMath.valueUsd(_pair(c), amount0, amount1, p0, p1);
    }

    function _pair(RangeCollateral memory c) internal pure returns (CollateralInput memory pair) {
        (pair.token0, pair.token1) = (c.shape.token0, c.shape.token1);
        (pair.price0Wad, pair.price1Wad, pair.decimals0, pair.decimals1) =
        (c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        (pair.sigma0Wad, pair.sigma1Wad) = (c.sigma0Wad, c.sigma1Wad);
    }

    function toShares(uint256 assets, uint256 totalAssets, uint256 totalShares, bool up)
        external
        pure
        returns (uint256)
    {
        return MarketLogic.toShares(assets, totalAssets, totalShares, up ? Rounding.Up : Rounding.Down);
    }

    function toAssets(uint256 shares, uint256 totalAssets, uint256 totalShares, bool up)
        external
        pure
        returns (uint256)
    {
        return MarketLogic.toAssets(shares, totalAssets, totalShares, up ? Rounding.Up : Rounding.Down);
    }

    function expWad(int256 x) external pure returns (int256) {
        return FixedPointMathLib.expWad(x);
    }

    function lnWad(int256 x) external pure returns (int256) {
        return FixedPointMathLib.lnWad(x);
    }

    /// @notice The period's integral, the rate at target it ends at, and the growth an accrual compounds from it
    function adaptiveRate(uint256 rateAtTarget, uint256 util, uint256 elapsed)
        external
        pure
        returns (uint256 integral, uint256 endRateAtTarget, int256 growth)
    {
        (integral, endRateAtTarget) = MarketLogic.adaptiveRate(rateAtTarget, util, elapsed);
        uint256 exponent = integral < MarketLogic.MAX_GROWTH_EXPONENT ? integral : MarketLogic.MAX_GROWTH_EXPONENT;
        growth = MarketLogic.expMinusOne(int256(exponent));
    }

    /// @notice A market's utilization and its borrow and supply rates now
    function marketRates(Market memory market) external pure returns (uint256, uint256, uint256) {
        uint256 borrowRate = MarketLogic.borrowRate(market);
        return (MarketLogic.utilization(market), borrowRate, MarketLogic.supplyRate(market, borrowRate));
    }

    function accrue(Market memory market, uint256 totalSupplyShares)
        external
        view
        returns (uint256 interest, uint256 reserveShares, Market memory)
    {
        uint256 reserveAssets;
        (interest, reserveAssets) = MarketLogic.accrue(market);
        reserveShares = MarketLogic.reserveShares(market, reserveAssets, totalSupplyShares);
        return (interest, reserveShares, market);
    }

    function addDebt(Market memory market, uint256 assets, uint256 fee, uint256 totalSupplyShares)
        external
        returns (uint256 shares, uint256 feeShares, Market memory)
    {
        market.exists = true;
        _borrowable.markets[OTHER] = market;
        (shares, feeShares) = BorrowLogic.addDebt(
            _borrowable, _borrowable.markets[OTHER], OTHER, address(this), ++_nextId, assets, fee, totalSupplyShares
        );
        return (shares, feeShares, _borrowable.markets[OTHER]);
    }

    function repayAmounts(Market memory market, uint256 debtShares, uint256 assets)
        external
        returns (uint256, uint256)
    {
        market.exists = true;
        _borrowable.markets[OTHER] = market;
        uint256 id = ++_nextId;
        _borrowable.debts[address(this)][id] = DebtLane.unwrap(DebtLanes.lane(market.index, debtShares));
        return BorrowLogic.repayAmounts(_borrowable, _borrowable.markets[OTHER], address(this), id, assets);
    }

    function feeCut(uint256 amount, uint256 cutWad) external pure returns (uint256) {
        return FeeLogic.cut(amount, cutWad);
    }

    function mergeMark(uint256 heldMark, uint256 movedMark, uint256 held, uint256 units, uint256 growthX128)
        external
        pure
        returns (uint256)
    {
        return FeeLogic.mergeMark(heldMark, movedMark, held, units, growthX128);
    }

    function feesPending(FeeCheckpoint memory cp, uint256 balance, uint256 fg0, uint256 fg1)
        external
        pure
        returns (uint256, uint256)
    {
        return FeeLogic.pending(cp, balance, fg0, fg1);
    }

    function feesCheckpoint(FeeCheckpoint memory cp, uint256 balance, uint256 fg0, uint256 fg1)
        external
        returns (FeeCheckpoint memory)
    {
        _checkpoint = cp;
        FeeLogic.checkpoint(_checkpoint, balance, fg0, fg1);
        return _checkpoint;
    }

    function liquidate(address asset, uint256 maxRepayAssets)
        external
        view
        returns (uint256 seizedUnits, uint256 repayAssets, uint256 feeAssets)
    {
        HealthLogic.Modules memory modules =
            HealthLogic.Modules(address(this), address(this), address(this), address(this));
        return LiquidationLogic.liquidate(modules, address(this), POSITION, asset, maxRepayAssets, _units, _units);
    }

    /// @dev A liquidation from the health check's numbers on: collateral and debt in USD, then the debt repaid
    function seizeFor(
        uint256 collateralUsd,
        uint256 debtUsd,
        uint256 debt,
        uint256 priceWad,
        uint8 decimals,
        uint256 penaltyWad,
        uint256 maxRepayAssets,
        uint256 units
    ) external pure returns (uint256 seizedUnits, uint256 repayAssets) {
        HealthResult memory health;
        (health.collateralUsdWad, health.debtUsdWad) = (collateralUsd, debtUsd);
        HealthLogic.Debt memory d = HealthLogic.Debt(address(0), debt, priceWad, decimals, penaltyWad);
        (seizedUnits, repayAssets,) = LiquidationLogic.seizeFor(health, d, maxRepayAssets, units, 0, false);
    }

    /// @dev `seizeFor` with the protocol fee: the DEX's `feeWad` and whether another debt remains
    function seizeForWithFee(uint256[8] calldata v, uint256 feeWad, bool hasOtherDebt)
        external
        pure
        returns (uint256 seizedUnits, uint256 repayAssets, uint256 feeAssets)
    {
        HealthResult memory health;
        (health.collateralUsdWad, health.debtUsdWad) = (v[0], v[1]);
        HealthLogic.Debt memory d = HealthLogic.Debt(address(0), v[2], v[3], uint8(v[4]), v[5]);
        return LiquidationLogic.seizeFor(health, d, v[6], v[7], feeWad, hasOtherDebt);
    }

    /// @dev What `seizeFor` weighs against the collateral with no other debt: the repayment's worth times the penalty
    function seizeUsd(uint256[8] calldata v) external pure returns (uint256) {
        uint256 repay = v[6] < v[2] ? v[6] : v[2];
        return FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(repay, v[3], 10 ** v[4]), v[5], 1e18);
    }
}
