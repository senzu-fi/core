// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {HealthMath} from "../src/libraries/HealthMath.sol";
import {RangeAmounts} from "../src/libraries/RangeAmounts.sol";
import {CollateralInput, DebtInput, DebtTie, HealthResult, Holdings, Shape} from "../src/libraries/Types.sol";
import {LiquidityAmounts} from "../src/libraries/uniswap/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Test} from "forge-std/Test.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

contract HealthMathTest is Test {
    uint256 constant WAD = 1e18;

    // ETH/USDC example
    uint256 constant ETH_PRICE = 2000e18;
    uint256 constant USDC_PRICE = 1e18;
    uint256 constant SIGMA_ETH = 1.15e18;
    uint256 constant SIGMA_USDC = 1.02e18;
    uint256 constant PENALTY = 1.05e18;

    /// @dev A range position: its pair, the range and the account's liquidity in it
    struct RangeCase {
        Shape shape;
        uint128 accountLiquidity;
        uint256 price0Wad;
        uint256 price1Wad;
        uint8 decimals0;
        uint8 decimals1;
        uint256 sigma0Wad;
        uint256 sigma1Wad;
    }

    /*  ================================================
                            Helpers
        ================================================  */

    function _pair(RangeCase memory c) internal pure returns (CollateralInput memory pair) {
        (pair.token0, pair.token1) = (c.shape.token0, c.shape.token1);
        (pair.price0Wad, pair.price1Wad, pair.decimals0, pair.decimals1) =
        (c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        (pair.sigma0Wad, pair.sigma1Wad) = (c.sigma0Wad, c.sigma1Wad);
    }

    /// @dev As the core runs it: what a range adapter reports at the check's prices, then the stress test
    function _evaluate(RangeCase memory c, DebtInput[] memory debts, uint256 penalty)
        internal
        pure
        returns (HealthResult memory)
    {
        CollateralInput memory pair = _pair(c);
        Holdings memory holdings =
            RangeAmounts.at(c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity, HealthMath.sqrtPrices(pair));
        return HealthMath.evaluate(pair, holdings, debts, penalty);
    }

    /// @dev The range's USD value at prices `p0`, `p1`
    function _valueAt(RangeCase memory c, uint256 p0, uint256 p1) internal pure returns (uint256) {
        if (c.accountLiquidity == 0) return 0;
        uint160 sqrtPriceX96 = HealthMath.sqrtPriceX96FromUsd(p0, p1, c.decimals0, c.decimals1);
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, c.shape.sqrtPaX96, c.shape.sqrtPbX96, c.accountLiquidity
        );
        return HealthMath.valueUsd(_pair(c), amount0, amount1, p0, p1);
    }

    function _ethUsdc(uint160 sqrtPa, uint160 sqrtPb) internal pure returns (RangeCase memory c) {
        c.shape = Shape({token0: address(1), token1: address(2), sqrtPaX96: sqrtPa, sqrtPbX96: sqrtPb, liquidity: 1e17});
        c.accountLiquidity = 1e17;
        c.price0Wad = ETH_PRICE;
        c.price1Wad = USDC_PRICE;
        c.decimals0 = 18;
        c.decimals1 = 6;
        c.sigma0Wad = SIGMA_ETH;
        c.sigma1Wad = SIGMA_USDC;
    }

    function _fullRange() internal pure returns (RangeCase memory) {
        return _ethUsdc(TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE);
    }

    /// @dev ±1% price range around the current oracle price
    function _narrow() internal pure returns (RangeCase memory) {
        uint160 sqrtP = HealthMath.sqrtPriceX96FromUsd(ETH_PRICE, USDC_PRICE, 18, 6);
        return _ethUsdc(uint160(uint256(sqrtP) * 994987437 / 1e9), uint160(uint256(sqrtP) * 1004987562 / 1e9));
    }

    function _oneDebt(uint256 valueUsd, DebtTie tie, uint256 sigma) internal pure returns (DebtInput[] memory debts) {
        debts = new DebtInput[](1);
        debts[0] = DebtInput({valueUsdWad: valueUsd, sigmaWad: sigma, tie: tie});
    }

    /// @dev Checks the liquidation threshold LTV sits within ±0.2% of `expectedLtv`
    function _assertThreshold(RangeCase memory c, DebtTie tie, uint256 sigmaDebt, uint256 expectedLtv) internal pure {
        uint256 collateral = _valueAt(c, c.price0Wad, c.price1Wad);

        HealthResult memory safe =
            _evaluate(c, _oneDebt(collateral * (expectedLtv - 0.002e18) / WAD, tie, sigmaDebt), PENALTY);
        assertGe(safe.minSurplusUsdWad, 0, "should be healthy just below the threshold");
        assertGe(safe.healthWad, WAD);

        HealthResult memory bad =
            _evaluate(c, _oneDebt(collateral * (expectedLtv + 0.002e18) / WAD, tie, sigmaDebt), PENALTY);
        assertLt(bad.minSurplusUsdWad, 0, "should be liquidatable just above the threshold");
        assertLt(bad.healthWad, WAD);
    }

    /*  ================================================
                        Price conversion
        ================================================  */

    function test_sqrt_edges() public pure {
        assertEq(FixedPointMathLib.sqrt(0), 0);
        assertEq(FixedPointMathLib.sqrt(1), 1);
        assertEq(FixedPointMathLib.sqrt(3), 1);
        assertEq(FixedPointMathLib.sqrt(4), 2);
        assertEq(FixedPointMathLib.sqrt(type(uint256).max), type(uint128).max);
        assertEq(FixedPointMathLib.sqrt(uint256(type(uint128).max) * type(uint128).max), type(uint128).max);
        assertEq(FixedPointMathLib.sqrt(uint256(type(uint128).max) * type(uint128).max - 1), type(uint128).max - 1);
    }

    /// @notice floor(sqrt(x)): z² ≤ x < (z + 1)², for every magnitude of x and around perfect squares
    function testFuzz_sqrt_isFloor(uint256 x, uint8 shift, uint128 root, int8 nudge) public pure {
        _assertFloorSqrt(x >> shift);
        uint256 square = uint256(root) * root;
        unchecked {
            uint256 near = square + uint256(int256(nudge));
            if (nudge < 0 ? near < square : near >= square) _assertFloorSqrt(near);
        }
    }

    function _assertFloorSqrt(uint256 x) internal pure {
        uint256 z = FixedPointMathLib.sqrt(x);
        assertLe(z, type(uint128).max);
        assertLe(z * z, x);
        if (z < type(uint128).max) assertGt((z + 1) * (z + 1), x);
    }

    /// @dev Each corner's pool price is the oracle's ratio at that corner's stressed prices, the ones `evaluate`
    ///      values its holdings at
    function testFuzz_sqrtPrices_eachCornerAtItsStressedPrices(uint96 price0, uint96 price1, uint8 corner) public pure {
        CollateralInput memory pair;
        (pair.price0Wad, pair.price1Wad) = (bound(price0, 1, type(uint96).max), bound(price1, 1, type(uint96).max));
        (pair.decimals0, pair.decimals1, pair.sigma0Wad, pair.sigma1Wad) = (18, 6, SIGMA_ETH, SIGMA_USDC);
        corner = uint8(bound(corner, 0, HealthMath.CORNERS - 1));
        (uint256 stressed0, uint256 stressed1) =
            HealthMath.stressedPrices(pair.price0Wad, pair.price1Wad, pair.sigma0Wad, pair.sigma1Wad, corner);
        assertEq(HealthMath.sqrtPrices(pair)[1 + corner], HealthMath.sqrtPriceX96FromUsd(stressed0, stressed1, 18, 6));
    }

    /// @dev A price of a wei stressed down rounds to 0: the top price, not a division by zero
    function test_sqrtPrices_aWeiPriceStressedToZero() public pure {
        CollateralInput memory pair;
        (pair.price0Wad, pair.price1Wad, pair.decimals0, pair.decimals1) = (1e18, 1, 18, 18);
        (pair.sigma0Wad, pair.sigma1Wad) = (WAD, 2e18);
        assertEq(HealthMath.sqrtPrices(pair)[1], TickMath.MAX_SQRT_PRICE, "token1 down to 0");
    }

    function test_sqrtPrice_equalPricesIsOne() public pure {
        assertEq(HealthMath.sqrtPriceX96FromUsd(1e18, 1e18, 18, 18), 1 << 96);
    }

    function test_sqrtPrice_ethUsdc() public pure {
        // sqrt(2000 · 1e6 / 1e18) · 2^96
        assertApproxEqRel(HealthMath.sqrtPriceX96FromUsd(ETH_PRICE, USDC_PRICE, 18, 6), 3543191142285914205922034, 1e9);
    }

    function test_sqrtPrice_clamps() public pure {
        assertEq(HealthMath.sqrtPriceX96FromUsd(1e40, 1, 18, 18), TickMath.MAX_SQRT_PRICE);
        assertEq(HealthMath.sqrtPriceX96FromUsd(1, 1e40, 18, 18), TickMath.MIN_SQRT_PRICE);
    }

    /// @notice Below a ratio of 2^64 the √price keeps all 96 fractional bits: ⌊√ratio · 2^96⌋
    function testFuzz_sqrtPrice_fullPrecisionBelow2To64(uint256 price0, uint256 price1, uint8 dec0, uint8 dec1)
        public
        pure
    {
        price0 = bound(price0, 1, 1e30);
        price1 = bound(price1, 1, 1e30);
        dec0 = uint8(bound(dec0, 0, 24));
        dec1 = uint8(bound(dec1, 0, 24));
        uint256 numerator = price0 * 10 ** dec1;
        uint256 denominator = price1 * 10 ** dec0;
        vm.assume(numerator / denominator < 1 << 64);

        uint256 r = HealthMath.sqrtPriceX96FromUsd(price0, price1, dec0, dec1);
        vm.assume(r > TickMath.MIN_SQRT_PRICE && r < TickMath.MAX_SQRT_PRICE);
        uint256 x = FullMath.mulDiv(numerator, 1 << 192, denominator);
        assertLe(r * r, x);
        assertGt((r + 1) * (r + 1), x);
    }

    /// @notice A $3e-11 token with 24 decimals against a $4,606 one with 0: near Uniswap's lowest √price, where a
    ///         64-bit root returned 2^32 (clamped to MIN_SQRT_PRICE, 32% low) and the check over-valued the position
    function test_sqrtPrice_nearTheLowestPriceKeepsPrecision() public pure {
        assertEq(HealthMath.sqrtPriceX96FromUsd(29578261, 4606439050521042000000, 24, 0), 6348677079);
    }

    /*  ================================================
                      Worked examples
        ================================================  */

    function test_fullRange_borrowUsdc() public pure {
        _assertThreshold(_fullRange(), DebtTie.Token1, 0, 0.8793e18);
    }

    function test_fullRange_borrowEth() public pure {
        _assertThreshold(_fullRange(), DebtTie.Token0, 0, 0.8793e18);
    }

    function test_fullRange_borrowUnrelated() public pure {
        _assertThreshold(_fullRange(), DebtTie.None, 1.3e18, 0.6764e18);
    }

    function test_narrow_borrowUsdc() public pure {
        _assertThreshold(_narrow(), DebtTie.Token1, 0, 0.814e18);
    }

    function test_narrow_borrowUnrelated() public pure {
        _assertThreshold(_narrow(), DebtTie.None, 1.3e18, 0.6387e18);
    }

    /*  ================================================
                           Edge cases
        ================================================  */

    function test_noDebt() public pure {
        HealthResult memory r = _evaluate(_fullRange(), new DebtInput[](0), PENALTY);
        assertEq(r.healthWad, type(uint256).max);
        assertGt(r.minSurplusUsdWad, 0);
        assertEq(r.debtUsdWad, 0);
    }

    function test_zeroLiquidity() public pure {
        RangeCase memory c = _fullRange();
        c.accountLiquidity = 0;
        HealthResult memory r = _evaluate(c, _oneDebt(1e18, DebtTie.Token1, 0), PENALTY);
        assertEq(r.collateralUsdWad, 0);
        assertLt(r.minSurplusUsdWad, 0);
    }

    function test_revertsOnSigmaBelowOne() public {
        RangeCase memory c = _fullRange();
        c.sigma0Wad = 0.9e18;
        vm.expectRevert(HealthMath.HealthMath__InvalidSigma.selector);
        this.evaluateExternal(c, new DebtInput[](0), PENALTY);
    }

    function evaluateExternal(RangeCase memory c, DebtInput[] memory debts, uint256 penalty)
        external
        pure
        returns (HealthResult memory)
    {
        return _evaluate(c, debts, penalty);
    }

    /*  ================================================
                     Fuzz: corners vs grid
        ================================================  */

    uint256 constant GRID = 7;

    /// @dev Surplus at an arbitrary point (q0, q1) of the stress box, priced the same way as the corners
    function _surplusAt(RangeCase memory c, DebtInput memory d, uint256 q0, uint256 q1, uint256 penalty)
        internal
        pure
        returns (int256)
    {
        uint256 collateral = _valueAt(c, FullMath.mulDiv(c.price0Wad, q0, WAD), FullMath.mulDiv(c.price1Wad, q1, WAD));
        uint256 debt;
        if (d.tie == DebtTie.Token0) debt = FullMath.mulDivRoundingUp(d.valueUsdWad, q0, WAD);
        else if (d.tie == DebtTie.Token1) debt = FullMath.mulDivRoundingUp(d.valueUsdWad, q1, WAD);
        else debt = FullMath.mulDivRoundingUp(d.valueUsdWad, d.sigmaWad, WAD);
        return int256(collateral) - int256(FullMath.mulDivRoundingUp(debt, penalty, WAD));
    }

    /// @notice The minimum over the 4 corners is never above the surplus anywhere inside the stress box
    function testFuzz_cornersAreTheMinimum(
        uint256 price0,
        uint256 price1,
        bool decimals0Is18,
        bool decimals1Is18,
        uint256 sigma0,
        uint256 sigma1,
        uint256 lowerFactor,
        uint256 upperFactor,
        uint128 liquidity,
        uint256 ltv,
        uint8 tieSeed
    ) public pure {
        RangeCase memory c;
        c.price0Wad = bound(price0, 1e16, 1e22); // $0.01 .. $10k
        c.price1Wad = bound(price1, 1e16, 1e22);
        c.decimals0 = decimals0Is18 ? 18 : 6;
        c.decimals1 = decimals1Is18 ? 18 : 6;
        c.sigma0Wad = bound(sigma0, 1.01e18, 1.5e18);
        c.sigma1Wad = bound(sigma1, 1.01e18, 1.5e18);
        c.accountLiquidity = uint128(bound(liquidity, 1e12, 1e24));

        // Range between 0.3x and 3x of the current price (in sqrt terms), current price may sit outside it
        uint256 sqrtP = HealthMath.sqrtPriceX96FromUsd(c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        uint256 a = sqrtP * bound(lowerFactor, 0.55e18, 1.7e18) / WAD;
        uint256 b = sqrtP * bound(upperFactor, 0.55e18, 1.7e18) / WAD;
        if (a == b) b = a + a / 100 + 1;
        c.shape.sqrtPaX96 = uint160(a < b ? a : b);
        c.shape.sqrtPbX96 = uint160(a < b ? b : a);

        uint256 collateralNow = _valueAt(c, c.price0Wad, c.price1Wad);
        vm.assume(collateralNow > 1e18); // at least $1 so relative tolerance is meaningful

        DebtInput[] memory debts = new DebtInput[](1);
        debts[0] = DebtInput({
            valueUsdWad: collateralNow * bound(ltv, 0.1e18, 1.2e18) / WAD, sigmaWad: 1.2e18, tie: DebtTie(tieSeed % 3)
        });

        HealthResult memory r = _evaluate(c, debts, PENALTY);

        // Tolerance for rounding between the corner path and the grid path: the corner √price (base √price × √σ)
        // and the grid's (from the stressed USD prices) differ in the last bits, which can move a token amount across
        // an integer boundary, so one smallest unit of each token (at its highest stressed price) on top
        uint256 oneUnitEach = FullMath.mulDiv(c.price0Wad, c.sigma0Wad, 10 ** c.decimals0 * WAD)
            + FullMath.mulDiv(c.price1Wad, c.sigma1Wad, 10 ** c.decimals1 * WAD) + 2;
        int256 tolerance = int256(collateralNow / 1e9 + 1e6 + oneUnitEach);

        for (uint256 i; i < GRID; ++i) {
            // q from 1/σ to σ
            uint256 q0 = WAD * WAD / c.sigma0Wad + (c.sigma0Wad - WAD * WAD / c.sigma0Wad) * i / (GRID - 1);
            for (uint256 j; j < GRID; ++j) {
                uint256 q1 = WAD * WAD / c.sigma1Wad + (c.sigma1Wad - WAD * WAD / c.sigma1Wad) * j / (GRID - 1);
                assertLe(r.minSurplusUsdWad, _surplusAt(c, debts[0], q0, q1, PENALTY) + tolerance);
            }
        }
    }

    /*  ================================================
             Fuzz: fast corner prices vs full sqrt
        ================================================  */

    /// @notice evaluate derives corner sqrt prices from √σ; the result matches pricing every corner from scratch
    function testFuzz_cornerSqrtPricesMatchFullComputation(
        uint256 price0,
        uint256 price1,
        bool decimals0Is18,
        bool decimals1Is18,
        uint256 sigma0,
        uint256 sigma1,
        uint256 lowerFactor,
        uint256 upperFactor,
        uint128 liquidity,
        uint8 tieSeed
    ) public pure {
        RangeCase memory c;
        c.price0Wad = bound(price0, 1e14, 1e24);
        c.price1Wad = bound(price1, 1e14, 1e24);
        c.decimals0 = decimals0Is18 ? 18 : 6;
        c.decimals1 = decimals1Is18 ? 18 : 8;
        c.sigma0Wad = bound(sigma0, 1e18, 3e18);
        c.sigma1Wad = bound(sigma1, 1e18, 3e18);
        c.accountLiquidity = uint128(bound(liquidity, 1e12, 1e24));

        uint256 sqrtP = HealthMath.sqrtPriceX96FromUsd(c.price0Wad, c.price1Wad, c.decimals0, c.decimals1);
        uint256 a = sqrtP * bound(lowerFactor, 0.3e18, 3e18) / WAD;
        uint256 b = sqrtP * bound(upperFactor, 0.3e18, 3e18) / WAD;
        if (a == b) b = a + a / 100 + 1;
        c.shape.sqrtPaX96 = uint160(a < b ? a : b);
        c.shape.sqrtPbX96 = uint160(a < b ? b : a);

        uint256 collateralNow = _valueAt(c, c.price0Wad, c.price1Wad);
        vm.assume(collateralNow > 1e18);

        DebtInput[] memory debts = new DebtInput[](1);
        debts[0] = DebtInput({valueUsdWad: collateralNow / 2, sigmaWad: 1.2e18, tie: DebtTie(tieSeed % 3)});
        HealthResult memory r = _evaluate(c, debts, PENALTY);

        int256 expected = type(int256).max;
        for (uint8 corner; corner < 4; ++corner) {
            (uint256 s0, uint256 s1) =
                HealthMath.stressedPrices(c.price0Wad, c.price1Wad, c.sigma0Wad, c.sigma1Wad, corner);
            uint256 q0 = FullMath.mulDiv(s0, WAD, c.price0Wad);
            uint256 q1 = FullMath.mulDiv(s1, WAD, c.price1Wad);
            int256 surplus = _surplusAt(c, debts[0], q0, q1, PENALTY);
            if (surplus < expected) expected = surplus;
        }

        // Only rounding differs: the corner's √price is floored
        assertApproxEqAbs(r.minSurplusUsdWad, expected, collateralNow / 1e8 + 1e6);
    }
}
