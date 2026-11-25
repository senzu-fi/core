// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {ISenzuPreviews} from "../interfaces/ISenzuPreviews.sol";
import {BorrowLogic} from "../libraries/BorrowLogic.sol";
import {HealthMath} from "../libraries/HealthMath.sol";
import {MarketLogic} from "../libraries/MarketLogic.sol";
import {CollateralInput, DebtInput, DebtTie, HealthResult, Holdings, Rounding, WAD} from "../libraries/Types.sol";
import {LiquidityAmounts} from "../libraries/uniswap/LiquidityAmounts.sol";
import {SenzuLens} from "./SenzuLens.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 *  @title  SenzuPreviews
 *  @author Senzu
 *  @notice Position previews; not deployed, the reference the SDK core ports bit-exact. Max borrow and max leverage
 *          are exact to 1e-6 relative. A position not opened yet is a range (`sqrtPaX96`, `sqrtPbX96`): previews of
 *          opens are for range adapters
 */
contract SenzuPreviews is SenzuLens, ISenzuPreviews {
    using SafeCastLib for uint256;

    uint256 internal constant MAX_LEVERAGE = 100e18;

    uint128 internal constant REF_LIQUIDITY = 1e18;
    uint256 internal constant MAX_DEBT_PER_VALUE = 10;
    /// @dev The most debts a position may have (`DebtLanes`)
    uint256 internal constant MAX_DEBTS = 2;

    constructor(address collateral_) SenzuLens(collateral_) {}

    /// @dev Previews run at the oracle's prices, as the core would: none on a closed market
    function _priceSource() internal view override returns (address) {
        return address(_oracle);
    }

    /// @inheritdoc ISenzuPreviews
    function maxBorrow(address account, uint256 id, address asset) external view override returns (uint256) {
        if (!_exists(id)) return 0;
        (
            CollateralInput memory input,
            Holdings memory holdings,
            DebtInput[] memory debts,
            DebtView[] memory views,
            uint256 penalty
        ) = _positionInputs(account, id);

        DebtInput[] memory others = _without(debts, views, asset);
        // Two debts in other assets: no room for a third
        if (others.length >= MAX_DEBTS) return 0;
        DebtBook memory book = _book(asset, account, id);

        uint256 limit = book.supplyAssets - book.borrowAssets;

        (uint256 price, uint8 decimals) = _priceOf(asset);
        (DebtInput memory added, uint256 addedPenalty, bool liquid) = _newDebt(input, asset, 0);
        if (!liquid) return 0;
        penalty = _max(penalty, addedPenalty);
        uint256 feeWad = _borrowFeeWad();

        uint256 valueUsd =
            HealthMath.valueUsd(input, holdings.amounts0[0], holdings.amounts1[0], input.price0Wad, input.price1Wad);
        uint256 hi = _min(limit, FixedPointMathLib.fullMulDiv(valueUsd * MAX_DEBT_PER_VALUE, 10 ** decimals, price));
        if (_surplusWithDebt(input, holdings, others, added, _booked(book, hi, feeWad), price, decimals, penalty) >= 0)
        {
            return hi;
        }
        if (_surplusWithDebt(input, holdings, others, added, _booked(book, 0, feeWad), price, decimals, penalty) < 0) {
            return 0;
        }

        uint256 lo;
        while (hi - lo > 1 && hi - lo > lo / 1e6) {
            uint256 mid = (lo + hi) / 2;
            if (
                _surplusWithDebt(input, holdings, others, added, _booked(book, mid, feeWad), price, decimals, penalty)
                    >= 0
            ) {
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    /// @inheritdoc ISenzuPreviews
    function previewOpen(OpenParams calldata params) external view override returns (OpenPreview memory preview) {
        if (params.borrowAssets.length != params.borrowAmounts.length) revert SenzuPreviews__LengthMismatch();
        (CollateralInput memory input, uint256 penalty) = _pairInput(params.token0, params.token1);
        preview.marginUsdWad = _usd(params.deposit0, input.price0Wad, input.decimals0)
            + _usd(params.deposit1, input.price1Wad, input.decimals1);

        uint256 total0 = params.deposit0;
        uint256 total1 = params.deposit1;
        uint256 otherUsd;
        bool illiquid;
        uint256 borrowed;
        uint256 feeWad = _borrowFeeWad();
        DebtInput[] memory debts = new DebtInput[](params.borrowAssets.length);
        for (uint256 i; i < debts.length; ++i) {
            address asset = params.borrowAssets[i];
            uint256 amount = params.borrowAmounts[i];
            if (asset == params.token0) {
                total0 += amount;
            } else if (asset == params.token1) {
                total1 += amount;
            } else {
                (uint256 price, uint8 decimals) = _priceOf(asset);
                otherUsd += _usd(amount, price, decimals);
            }
            uint256 debtPenalty;
            bool liquid;
            (debts[i], debtPenalty, liquid) =
                _newDebt(input, asset, _booked(_book(asset, address(0), 0), amount, feeWad));
            if (amount != 0) {
                ++borrowed;
                penalty = _max(penalty, debtPenalty);
                if (!liquid) illiquid = true;
            }
            preview.debtUsdWad += debts[i].valueUsdWad;
        }

        Valuation memory range = _ofRange(
            params.sqrtPaX96,
            params.sqrtPbX96,
            params.swap
                ? _liquidityForUsd(
                    input,
                    params.sqrtPaX96,
                    params.sqrtPbX96,
                    _usd(total0, input.price0Wad, input.decimals0) + _usd(total1, input.price1Wad, input.decimals1)
                        + otherUsd
                )
                : _liquidityForAmounts(input, params.sqrtPaX96, params.sqrtPbX96, total0, total1)
        );

        (preview.amount0, preview.amount1) = LiquidityAmounts.getAmountsForLiquidity(
            _oracleSqrtPrice(input), range.sqrtPaX96, range.sqrtPbX96, range.liquidity
        );
        preview.liquidity = range.liquidity;

        HealthResult memory h = _evaluate(range, input, debts, penalty);
        preview.collateralUsdWad = h.collateralUsdWad;
        preview.healthWad = h.healthWad;
        if (preview.marginUsdWad != 0) {
            preview.leverageWad = FixedPointMathLib.fullMulDiv(h.collateralUsdWad, WAD, preview.marginUsdWad);
        }
        preview.allowed = h.minSurplusUsdWad >= 0 && !illiquid && borrowed <= MAX_DEBTS;
        preview.liquidation = _liquidationPrices(range, input, debts, penalty);
    }

    /// @inheritdoc ISenzuPreviews
    function maxLeverage(address token0, address token1, uint160 sqrtPaX96, uint160 sqrtPbX96, address borrowAsset)
        external
        view
        override
        returns (uint256)
    {
        (CollateralInput memory input, uint256 penalty) = _pairInput(token0, token1);

        uint256 value = _rangeValue(input, sqrtPaX96, sqrtPbX96, REF_LIQUIDITY);
        if (value == 0) return WAD;
        (uint256 amount0,) =
            LiquidityAmounts.getAmountsForLiquidity(_oracleSqrtPrice(input), sqrtPaX96, sqrtPbX96, REF_LIQUIDITY);
        uint256 share0 = FixedPointMathLib.fullMulDiv(_usd(amount0, input.price0Wad, input.decimals0), WAD, value);

        if (borrowAsset != address(0)) {
            (, uint256 borrowPenalty, bool liquid) = _newDebt(input, borrowAsset, 0);
            if (!liquid) return WAD;
            penalty = _max(penalty, borrowPenalty);
        }
        uint256 feeWad = _borrowFeeWad();
        Valuation memory range = _ofRange(sqrtPaX96, sqrtPbX96, 0);
        uint256 lo = WAD;
        uint256 hi = MAX_LEVERAGE;
        if (_leverageSurplus(range, input, value, share0, borrowAsset, hi, penalty, feeWad) >= 0) return hi;
        while (hi - lo > lo / 1e6) {
            uint256 mid = (lo + hi) / 2;
            if (_leverageSurplus(range, input, value, share0, borrowAsset, mid, penalty, feeWad) >= 0) lo = mid;
            else hi = mid;
        }
        return lo;
    }

    /// @inheritdoc ISenzuPreviews
    function swapForRange(
        address token0,
        address token1,
        uint160 sqrtPaX96,
        uint160 sqrtPbX96,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 swapFeeWad
    ) external view override returns (SwapQuote memory quote) {
        if (sqrtPriceX96 == 0) {
            (CollateralInput memory input,) = _pairInput(token0, token1);
            sqrtPriceX96 = _oracleSqrtPrice(input);
        }
        uint256 keep = WAD - swapFeeWad;

        (uint160 a, uint160 b) = sqrtPaX96 < sqrtPbX96 ? (sqrtPaX96, sqrtPbX96) : (sqrtPbX96, sqrtPaX96);
        if (a == b) return quote;
        if (sqrtPriceX96 <= a) return _quote(false, amount1, sqrtPriceX96, keep);
        if (sqrtPriceX96 >= b) return _quote(true, amount0, sqrtPriceX96, keep);

        // Target value ratio token0 / token1 = s(b - s) / (b(s - a)), scaled by WAD.
        // Grouping the factor >= 1/2 with WAD keeps full 18-digit precision across the full uint160 range.
        uint256 s = sqrtPriceX96;
        uint256 r = s <= b / 2
            ? FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(b - s, WAD, b), s, s - a)
            : FixedPointMathLib.fullMulDiv(FixedPointMathLib.fullMulDiv(s, WAD, b), b - s, s - a);
        if (r == 0) return _quote(true, amount0, sqrtPriceX96, keep);

        uint256 sell0Denom = WAD + FixedPointMathLib.fullMulDiv(r, keep, WAD);
        if (s < 1 << 96) {
            uint256 x1 = _toToken1(amount0, sqrtPriceX96);
            if (r <= WAD) {
                uint256 ry = FixedPointMathLib.fullMulDiv(amount1, r, WAD);
                if (x1 > ry) {
                    uint256 excess0 = amount0 - _toToken0(ry, sqrtPriceX96);
                    return _quote(true, FixedPointMathLib.fullMulDiv(excess0, WAD, sell0Denom), sqrtPriceX96, keep);
                }
                return _quote(false, FixedPointMathLib.fullMulDiv(ry - x1, WAD, r + keep), sqrtPriceX96, keep);
            }
            uint256 x1OverR = FixedPointMathLib.fullMulDiv(x1, WAD, r);
            if (x1OverR < amount1) {
                return _quote(false, FixedPointMathLib.fullMulDiv(amount1 - x1OverR, r, r + keep), sqrtPriceX96, keep);
            }
            uint256 ry = FixedPointMathLib.fullMulDiv(amount1, r, WAD);
            uint256 excess0 = amount0 - _toToken0(ry, sqrtPriceX96);
            return _quote(true, FixedPointMathLib.fullMulDiv(excess0, WAD, sell0Denom), sqrtPriceX96, keep);
        }

        uint256 y0 = _toToken0(amount1, sqrtPriceX96);
        if (r <= WAD) {
            uint256 ry0 = FixedPointMathLib.fullMulDiv(y0, r, WAD);
            if (amount0 > ry0) {
                return _quote(true, FixedPointMathLib.fullMulDiv(amount0 - ry0, WAD, sell0Denom), sqrtPriceX96, keep);
            }
            uint256 xOverR = FixedPointMathLib.fullMulDiv(amount0, WAD, r);
            uint256 excess1 = amount1 - _toToken1(xOverR, sqrtPriceX96);
            return _quote(false, FixedPointMathLib.fullMulDiv(excess1, r, r + keep), sqrtPriceX96, keep);
        }
        uint256 xOverR = FixedPointMathLib.fullMulDiv(amount0, WAD, r);
        if (xOverR < y0) {
            uint256 excess1 = amount1 - _toToken1(xOverR, sqrtPriceX96);
            return _quote(false, FixedPointMathLib.fullMulDiv(excess1, r, r + keep), sqrtPriceX96, keep);
        }
        uint256 ry0 = FixedPointMathLib.fullMulDiv(y0, r, WAD);
        return _quote(true, FixedPointMathLib.fullMulDiv(amount0 - ry0, WAD, sell0Denom), sqrtPriceX96, keep);
    }

    function _quote(bool zeroForOne, uint256 amountIn, uint160 sqrtPriceX96, uint256 keep)
        internal
        pure
        returns (SwapQuote memory quote)
    {
        uint256 net = FixedPointMathLib.fullMulDiv(amountIn, keep, WAD);
        quote = SwapQuote({
            zeroForOne: zeroForOne,
            amountIn: amountIn,
            amountOut: zeroForOne ? _toToken1(net, sqrtPriceX96) : _toToken0(net, sqrtPriceX96)
        });
    }

    function _toToken1(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(amount, sqrtPriceX96, 1 << 96), sqrtPriceX96, 1 << 96
        );
    }

    function _toToken0(uint256 amount, uint160 sqrtPriceX96) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(
            FixedPointMathLib.fullMulDiv(amount, 1 << 96, sqrtPriceX96), 1 << 96, sqrtPriceX96
        );
    }

    function _surplusWithDebt(
        CollateralInput memory input,
        Holdings memory holdings,
        DebtInput[] memory others,
        DebtInput memory added,
        uint256 debt,
        uint256 price,
        uint8 decimals,
        uint256 penalty
    ) internal pure returns (int256) {
        DebtInput[] memory all = new DebtInput[](others.length + 1);
        for (uint256 i; i < others.length; ++i) {
            all[i] = others[i];
        }
        all[others.length] = DebtInput({
            valueUsdWad: FixedPointMathLib.fullMulDivUp(debt, price, 10 ** decimals),
            sigmaWad: added.sigmaWad,
            tie: added.tie
        });
        return HealthMath.evaluate(input, holdings, all, penalty).minSurplusUsdWad;
    }

    function _without(DebtInput[] memory debts, DebtView[] memory views, address asset)
        internal
        pure
        returns (DebtInput[] memory others)
    {
        uint256 n;
        for (uint256 i; i < views.length; ++i) {
            if (views[i].asset != asset) ++n;
        }
        others = new DebtInput[](n);
        uint256 k;
        for (uint256 i; i < views.length; ++i) {
            if (views[i].asset != asset) others[k++] = debts[i];
        }
    }

    struct DebtBook {
        uint256 supplyAssets;
        uint256 borrowAssets;
        uint256 borrowShares;
        uint256 accountShares;
    }

    function _book(address asset, address account, uint256 id) internal view returns (DebtBook memory book) {
        (book.supplyAssets, book.borrowAssets,,,,) = ISenzuBorrowable(borrowable).marketState(asset);
        book.borrowShares = ISenzuBorrowable(borrowable).getMarket(asset).totalBorrowShares;
        if (account != address(0)) {
            book.accountShares = ISenzuBorrowable(borrowable).borrowSharesOf(account, id, asset);
        }
    }

    function _booked(DebtBook memory book, uint256 amount, uint256 feeWad) internal pure returns (uint256) {
        uint256 debt = _withFee(amount, feeWad);
        uint256 shares = MarketLogic.toShares(debt, book.borrowAssets, book.borrowShares, Rounding.Up);
        return MarketLogic.toAssets(
            book.accountShares + shares, book.borrowAssets + debt, book.borrowShares + shares, Rounding.Up
        );
    }

    function _leverageSurplus(
        Valuation memory range,
        CollateralInput memory input,
        uint256 value,
        uint256 share0,
        address borrowAsset,
        uint256 leverage,
        uint256 penalty,
        uint256 feeWad
    ) internal view returns (int256) {
        range.liquidity = FixedPointMathLib.fullMulDiv(REF_LIQUIDITY, leverage, WAD).toUint128();
        uint256 debtUsd = _withFee(FixedPointMathLib.fullMulDivUp(value, leverage - WAD, WAD), feeWad);

        DebtInput[] memory debts;
        if (borrowAsset == address(0)) {
            uint256 debt0 = FixedPointMathLib.fullMulDivUp(debtUsd, share0, WAD);
            debts = new DebtInput[](2);
            debts[0] = DebtInput({valueUsdWad: debt0, sigmaWad: input.sigma0Wad, tie: DebtTie.Token0});
            debts[1] = DebtInput({
                valueUsdWad: debtUsd - _min(debt0, debtUsd), sigmaWad: input.sigma1Wad, tie: DebtTie.Token1
            });
        } else {
            debts = new DebtInput[](1);
            (debts[0],,) = _newDebt(input, borrowAsset, 0);
            debts[0].valueUsdWad = debtUsd;
        }
        return _evaluate(range, input, debts, penalty).minSurplusUsdWad;
    }

    /// @dev USD value of `liquidity` between the two prices, at the oracle's prices
    function _rangeValue(CollateralInput memory input, uint160 sqrtPaX96, uint160 sqrtPbX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (liquidity == 0) return 0;
        (uint256 amount0, uint256 amount1) =
            LiquidityAmounts.getAmountsForLiquidity(_oracleSqrtPrice(input), sqrtPaX96, sqrtPbX96, liquidity);
        return HealthMath.valueUsd(input, amount0, amount1, input.price0Wad, input.price1Wad);
    }

    function _liquidityForUsd(CollateralInput memory input, uint160 sqrtPaX96, uint160 sqrtPbX96, uint256 usd)
        internal
        pure
        returns (uint128)
    {
        uint256 valuePerRef = _rangeValue(input, sqrtPaX96, sqrtPbX96, REF_LIQUIDITY);
        if (valuePerRef == 0) return 0;
        return FixedPointMathLib.fullMulDiv(usd, REF_LIQUIDITY, valuePerRef).toUint128();
    }

    function _liquidityForAmounts(
        CollateralInput memory input,
        uint160 sqrtPaX96,
        uint160 sqrtPbX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        (uint256 ref0, uint256 ref1) = LiquidityAmounts.getAmountsForLiquidity(
            _oracleSqrtPrice(input), sqrtPaX96, sqrtPbX96, REF_LIQUIDITY
        );
        uint256 liquidity = type(uint128).max;
        if (ref0 != 0) liquidity = _min(liquidity, FixedPointMathLib.fullMulDiv(amount0, REF_LIQUIDITY, ref0));
        if (ref1 != 0) liquidity = _min(liquidity, FixedPointMathLib.fullMulDiv(amount1, REF_LIQUIDITY, ref1));
        return ref0 == 0 && ref1 == 0 ? 0 : liquidity.toUint128();
    }

    function _borrowFeeWad() internal view returns (uint256) {
        return _risk.borrowFeeWad(address(_adapter));
    }

    function _priceOf(address asset) internal view returns (uint256, uint8) {
        return _oracle.priceWithDecimals(asset);
    }

    function _withFee(uint256 amount, uint256 feeWad) internal pure returns (uint256) {
        return amount + BorrowLogic.borrowFee(amount, feeWad);
    }

    function _usd(uint256 amount, uint256 priceWad, uint8 decimals) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amount, priceWad, 10 ** decimals);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
