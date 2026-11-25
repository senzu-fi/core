// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {CollateralInput, DebtInput, DebtTie, HealthResult, Holdings, WAD} from "./Types.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @notice The four-corner stress test of a position from what its adapter says it holds at each price. Rounding:
///         collateral rounds down, debt rounds up
library HealthMath {
    using SafeCastLib for uint256;

    uint8 internal constant CORNERS = 4;

    /// @notice Lowest and highest √price (X96) a check values a position at: Uniswap's TickMath range
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    /// @notice How many prices a health check values a position at: the oracle's, then each corner's
    uint256 internal constant PRICES = 1 + CORNERS;

    /// @notice Cached powers of 10 and stressed prices for a pair, shared between `sqrtPrices` and `evaluate`
    struct Stressed {
        uint256 scale0;
        uint256 scale1;
        uint256 p0Down;
        uint256 p0Up;
        uint256 p1Down;
        uint256 p1Up;
    }

    error HealthMath__InvalidSigma();

    error HealthMath__InvalidPrice();

    /// @notice Validates `collateral` and caches its decimal scales and four stressed prices
    function stressed(CollateralInput memory collateral) internal pure returns (Stressed memory s) {
        _check(collateral);
        s.scale0 = 10 ** collateral.decimals0;
        s.scale1 = 10 ** collateral.decimals1;
        s.p0Down = FixedPointMathLib.fullMulDiv(collateral.price0Wad, WAD, collateral.sigma0Wad);
        s.p0Up = FixedPointMathLib.fullMulDiv(collateral.price0Wad, collateral.sigma0Wad, WAD);
        s.p1Down = FixedPointMathLib.fullMulDiv(collateral.price1Wad, WAD, collateral.sigma1Wad);
        s.p1Up = FixedPointMathLib.fullMulDiv(collateral.price1Wad, collateral.sigma1Wad, WAD);
    }

    /// @notice The pool prices (√(token1 per token0) · 2^96) a health check values a position of `collateral`'s pair
    ///         at: the oracle's first, then corner `c`'s at 1 + c. Its adapter reports what it holds at each
    ///         (`amountsAt`)
    function sqrtPrices(CollateralInput memory collateral) internal pure returns (uint160[5] memory prices) {
        return sqrtPrices(collateral, stressed(collateral));
    }

    /// @notice `sqrtPrices` reusing cached scales and stressed prices from `stressed(collateral)`
    function sqrtPrices(CollateralInput memory collateral, Stressed memory s)
        internal
        pure
        returns (uint160[5] memory prices)
    {
        prices[0] = _sqrtPriceX96Scaled(collateral.price0Wad, collateral.price1Wad, s.scale0, s.scale1);
        prices[1] = _sqrtPriceX96Scaled(s.p0Down, s.p1Down, s.scale0, s.scale1);
        prices[2] = _sqrtPriceX96Scaled(s.p0Up, s.p1Down, s.scale0, s.scale1);
        prices[3] = _sqrtPriceX96Scaled(s.p0Down, s.p1Up, s.scale0, s.scale1);
        prices[4] = _sqrtPriceX96Scaled(s.p0Up, s.p1Up, s.scale0, s.scale1);
    }

    /// @notice The stress test: `holdings` at `sqrtPrices(collateral)`, each corner's valued at that corner's prices
    function evaluate(
        CollateralInput memory collateral,
        Holdings memory holdings,
        DebtInput[] memory debts,
        uint256 penaltyWad
    ) internal pure returns (HealthResult memory) {
        return evaluate(collateral, holdings, debts, penaltyWad, stressed(collateral));
    }

    /// @notice `evaluate` reusing cached scales and stressed prices from `stressed(collateral)`
    function evaluate(
        CollateralInput memory collateral,
        Holdings memory holdings,
        DebtInput[] memory debts,
        uint256 penaltyWad,
        Stressed memory s
    ) internal pure returns (HealthResult memory result) {
        result.collateralUsdWad = _valueUsd(
            holdings.amounts0[0], holdings.amounts1[0], collateral.price0Wad, collateral.price1Wad, s.scale0, s.scale1
        );

        uint256 d0Down;
        uint256 d0Up;
        uint256 d1Down;
        uint256 d1Up;
        uint256 dFixed;
        for (uint256 i; i < debts.length; ++i) {
            DebtInput memory debt = debts[i];
            result.debtUsdWad += debt.valueUsdWad;
            if (debt.tie == DebtTie.Token0) {
                d0Down += FixedPointMathLib.fullMulDivUp(debt.valueUsdWad, WAD, collateral.sigma0Wad);
                d0Up += FixedPointMathLib.fullMulDivUp(debt.valueUsdWad, collateral.sigma0Wad, WAD);
            } else if (debt.tie == DebtTie.Token1) {
                d1Down += FixedPointMathLib.fullMulDivUp(debt.valueUsdWad, WAD, collateral.sigma1Wad);
                d1Up += FixedPointMathLib.fullMulDivUp(debt.valueUsdWad, collateral.sigma1Wad, WAD);
            } else {
                if (debt.sigmaWad < WAD) revert HealthMath__InvalidSigma();
                dFixed += FixedPointMathLib.fullMulDivUp(debt.valueUsdWad, debt.sigmaWad, WAD);
            }
        }

        result.minSurplusUsdWad = type(int256).max;
        result.healthWad = type(uint256).max;

        _applyCorner(
            result,
            holdings.amounts0[1],
            holdings.amounts1[1],
            s.p0Down,
            s.p1Down,
            s,
            d0Down + d1Down + dFixed,
            penaltyWad
        );
        _applyCorner(
            result, holdings.amounts0[2], holdings.amounts1[2], s.p0Up, s.p1Down, s, d0Up + d1Down + dFixed, penaltyWad
        );
        _applyCorner(
            result, holdings.amounts0[3], holdings.amounts1[3], s.p0Down, s.p1Up, s, d0Down + d1Up + dFixed, penaltyWad
        );
        _applyCorner(
            result, holdings.amounts0[4], holdings.amounts1[4], s.p0Up, s.p1Up, s, d0Up + d1Up + dFixed, penaltyWad
        );
    }

    /// @notice USD value of `amount0` and `amount1` of the pair at the given prices, rounded down
    function valueUsd(
        CollateralInput memory collateral,
        uint256 amount0,
        uint256 amount1,
        uint256 price0Wad,
        uint256 price1Wad
    ) internal pure returns (uint256) {
        return _valueUsd(amount0, amount1, price0Wad, price1Wad, 10 ** collateral.decimals0, 10 ** collateral.decimals1);
    }

    function stressedPrices(uint256 price0Wad, uint256 price1Wad, uint256 sigma0Wad, uint256 sigma1Wad, uint8 corner)
        internal
        pure
        returns (uint256 stressed0Wad, uint256 stressed1Wad)
    {
        stressed0Wad = _stress(price0Wad, sigma0Wad, _token0Up(corner));
        stressed1Wad = _stress(price1Wad, sigma1Wad, _token1Up(corner));
    }

    /// @notice sqrt(p0 · 10^dec1 / (p1 · 10^dec0)) · 2^96, clamped to [MIN_SQRT_PRICE, MAX_SQRT_PRICE]
    function sqrtPriceX96FromUsd(uint256 price0Wad, uint256 price1Wad, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        return _sqrtPriceX96Scaled(price0Wad, price1Wad, 10 ** decimals0, 10 ** decimals1);
    }

    /// @notice sqrt(numerator / denominator) · 2^96, clamped to [MIN_SQRT_PRICE, MAX_SQRT_PRICE]: token1 per token0 in
    ///         raw units (a v2 pair's reserve1 / reserve0)
    function sqrtPriceX96FromRatio(uint256 numerator, uint256 denominator)
        internal
        pure
        returns (uint160 sqrtPriceX96)
    {
        // ratio >= 2^128 is above the highest Uniswap price anyway (a stressed price of a wei or two rounds to 0)
        uint256 ratio = denominator == 0 ? type(uint256).max : numerator / denominator;
        if (ratio >= 1 << 128) return MAX_SQRT_PRICE;

        // Below 2^64 the root keeps all 96 fractional bits; above, 64 do (2^192 · ratio would overflow)
        uint256 sqrtPrice = ratio < 1 << 64
            ? FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(numerator, 1 << 192, denominator))
            : FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(numerator, 1 << 128, denominator)) << 32;
        return _clampSqrtPrice(sqrtPrice);
    }

    function _sqrtPriceX96Scaled(uint256 price0Wad, uint256 price1Wad, uint256 scale0, uint256 scale1)
        private
        pure
        returns (uint160)
    {
        return sqrtPriceX96FromRatio(price0Wad * scale1, price1Wad * scale0);
    }

    /// @dev Rounded down
    function _valueUsd(
        uint256 amount0,
        uint256 amount1,
        uint256 price0Wad,
        uint256 price1Wad,
        uint256 scale0,
        uint256 scale1
    ) private pure returns (uint256) {
        return FixedPointMathLib.fullMulDiv(amount0, price0Wad, scale0)
            + FixedPointMathLib.fullMulDiv(amount1, price1Wad, scale1);
    }

    function _applyCorner(
        HealthResult memory result,
        uint256 amount0,
        uint256 amount1,
        uint256 price0Wad,
        uint256 price1Wad,
        Stressed memory s,
        uint256 stressedDebt,
        uint256 penaltyWad
    ) private pure {
        uint256 collateralUsd = _valueUsd(amount0, amount1, price0Wad, price1Wad, s.scale0, s.scale1);
        uint256 required = FixedPointMathLib.fullMulDivUp(stressedDebt, penaltyWad, WAD);

        int256 surplus = collateralUsd.toInt256() - required.toInt256();
        if (surplus < result.minSurplusUsdWad) result.minSurplusUsdWad = surplus;

        if (required > 0) {
            uint256 health = FixedPointMathLib.fullMulDiv(collateralUsd, WAD, required);
            if (health < result.healthWad) result.healthWad = health;
        }
    }

    function _clampSqrtPrice(uint256 sqrtPrice) private pure returns (uint160) {
        if (sqrtPrice < MIN_SQRT_PRICE) return MIN_SQRT_PRICE;
        if (sqrtPrice > MAX_SQRT_PRICE) return MAX_SQRT_PRICE;
        return sqrtPrice.toUint160();
    }

    function _check(CollateralInput memory collateral) private pure {
        if (collateral.sigma0Wad < WAD || collateral.sigma1Wad < WAD) revert HealthMath__InvalidSigma();
        if (collateral.price0Wad == 0 || collateral.price1Wad == 0) revert HealthMath__InvalidPrice();
    }

    function _token0Up(uint8 corner) private pure returns (bool) {
        return corner & 1 != 0;
    }

    function _token1Up(uint8 corner) private pure returns (bool) {
        return corner & 2 != 0;
    }

    /// @dev Rounded down
    function _stress(uint256 value, uint256 sigmaWad, bool up) private pure returns (uint256) {
        return
            up ? FixedPointMathLib.fullMulDiv(value, sigmaWad, WAD) : FixedPointMathLib.fullMulDiv(value, WAD, sigmaWad);
    }
}
