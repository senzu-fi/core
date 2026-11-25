// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {SdkVectorLines} from "./sdk/SdkVectorLines.sol";
import {Script} from "forge-std/Script.sol";

/**
 *  @title  SdkVectors
 *  @notice Writes the test vectors (`formal/vectors/`) that tie the Lean model and Senzu's off-chain math to
 *          the contracts. Every vector is an input, run through the real Solidity code, and its output or `err` when the
 *          contract reverts. Inputs are deterministic (keccak chain from a fixed seed), so regenerating gives the
 *          same files unless the contracts change.
 *
 *          forge script script/SdkVectors.s.sol
 *
 *          Format, one vector per line: space-separated decimal inputs, `=>`, then the outputs or `err`.
 *          Booleans are 0/1. Assets are 0 (token0), 1 (token1), 2 (another token).
 */
contract SdkVectors is Script {
    string internal constant DIR = "formal/vectors/";

    function run() external {
        SdkVectorLines g = new SdkVectorLines();

        _generate("mul_div", "a b denominator => mulDiv mulDivRoundingUp (each may be err)", g.lineMulDiv, 2000);
        _generate("sqrt", "x => sqrt", g.lineSqrt, 500);
        _generate("tick_math", "tick sqrtPrice => sqrtPriceAtTick(tick) tickAtSqrtPrice(sqrtPrice)", g.lineTick, 1500);
        _generate("amount_delta", "sqrtA sqrtB liquidity roundUp => amount0Delta amount1Delta", g.lineDelta, 1500);
        _generate("next_sqrt_price", "sqrtPrice liquidity amount zeroForOne isInput => next", g.lineNext, 2000);
        _generate(
            "liquidity_amounts",
            "sqrtP sqrtA sqrtB liquidity amount0 amount1 => amounts0 amounts1 liquidityFor",
            g.lineLiquidity,
            1500
        );
        _generate("sqrt_price_from_usd", "p0 p1 d0 d1 => sqrtPriceX96", g.lineSqrtFromUsd, 1500);
        _generate(
            "evaluate",
            "sqrtA sqrtB L p0 d0 s0 p1 d1 s1 penalty n [value sigma tie]*n => minSurplus health collateral debt",
            g.lineEvaluate,
            1500
        );
        _generate("collateral_usd_at", "sqrtA sqrtB L p0 d0 p1 d1 q0 q1 => value", g.lineCollateralUsdAt, 600);
        _generate("shares", "amount totalAssets totalShares up => toShares toAssets", g.lineShares, 1000);
        _generate("exp_wad", "x => expWad", g.lineExp, 1000);
        _generate(
            "adaptive_rate",
            "rateAtTarget utilization elapsed => integral endRateAtTarget growth",
            g.lineAdaptiveRate,
            1500
        );
        _generate(
            "accrue",
            "supply borrow borrowShares last reserveFactor remainder rateAtTarget supplyShares now => interest reserveShares supply borrow last remainder rateAtTarget",
            g.lineAccrue,
            1000
        );
        _generate(
            "market_rates",
            "supply borrow reserveFactor rateAtTarget => utilization borrowRate supplyRate",
            g.lineRates,
            600
        );
        _generate(
            "borrow",
            "supply borrow borrowShares assets fee supplyShares => shares feeShares supply borrow borrowShares",
            g.lineBorrow,
            1000
        );
        _generate("repay", "borrow borrowShares debtShares assets => repaid shares", g.lineRepay, 1000);
        _generate("fees", "fg0Last fg1Last owed0 owed1 balance fg0 fg1 => owed0 owed1", g.lineFees, 600);
        _generate(
            "liquidate",
            "COLLATERAL OTHER PENALTIES n [asset amount]*n units repayAsset maxRepay feeWad => repay seized fee",
            g.lineLiquidate,
            800
        );
        _generate(
            "swap_for_range",
            "sqrtA sqrtB amount0 amount1 sqrtPrice fee p0 d0 p1 d1 => zeroForOne amountIn amountOut",
            g.lineSwap,
            800
        );
        _append("swap_for_range", g.extremeSwapForRange());
        _generate("max_leverage", "COLLATERAL OTHER PENALTIES borrowFee mode => leverage", g.lineMaxLeverage, 150);
        _append("max_leverage", g.extremeMaxLeverage());
        _generate(
            "max_borrow",
            "COLLATERAL OTHER PENALTIES borrowFee n [asset amount]*n asset supply borrow borrowShares accountShares => amount",
            g.lineMaxBorrow,
            150
        );
        _append("max_borrow", g.extremeMaxBorrow());
        _generate(
            "preview_open",
            "COLLATERAL OTHER PENALTIES borrowFee deposit0 deposit1 swap n [asset amount]*n marketBorrow marketShares => liquidity amount0 amount1 collateral margin debt leverage health allowed moving lower upper",
            g.linePreviewOpen,
            150
        );
        _append("preview_open", g.extremePreviewOpen());
        // Last, so the generators above keep their draws
        _generate(
            "write_off",
            "supply borrow borrowShares debtShares => supply borrow borrowShares positionShares",
            g.lineWriteOff,
            1000
        );
        _generate("ln_wad", "x => lnWad", g.lineLn, 1000);
        _generate(
            "evaluate_holdings",
            "p0 d0 s0 p1 d1 s1 [amount0 amount1]*5 n [value sigma tie]*n penalty => sqrtPrices*5 | minSurplus health collateral debt",
            g.lineEvaluateHoldings,
            1500
        );
        _generate("fee_cut", "amount cutWad => cut paid", g.lineFeeCut, 1000);
        _generate(
            "repay_book",
            "supply borrow borrowShares debtShares assets => repaid supply borrow borrowShares positionShares",
            g.lineRepayBook,
            1000
        );
        _generate(
            "reward_ledger",
            "n [kind a b c d e f]*n (0 book lp arrived liquidity, 1 hold amount, 2 checkpoint account lp balance, 3 pay account lp, 4 seize from to lp fromBalance toBalance units; unused fields 0) => per step: - | paid | err (ends it); then | per lp: growth positionRewards; rewardsHeld; per account, lp: growth owed",
            g.lineRewardLedger,
            400
        );
        _generate(
            "seize",
            "collateralUsd debtUsd debt priceWad decimals penaltyWad maxRepay units => seized repay (LiquidationLogic.seizeFor)",
            g.lineSeize,
            1000
        );
        _generate(
            "merge_mark", "heldMark movedMark held units growth => mark (FeeLogic.mergeMark)", g.lineMergeMark, 1000
        );
        // Last, so every file above keeps its draws
        _generate(
            "seize_fee",
            "collateralUsd debtUsd debt priceWad decimals penaltyWad maxRepay units feeWad hasOtherDebt => seized repay fee (LiquidationLogic.seizeFor)",
            g.lineSeizeFee,
            2000
        );
        _generate(
            "fee_checkpoint",
            "fg0Last fg1Last owed0 owed1 balance fg0 fg1 => fg0Last fg1Last owed0 owed1 (FeeLogic.checkpoint)",
            g.lineFeeCheckpoint,
            600
        );
        _generate(
            "liquidation_prices",
            "COLLATERAL penalty n [value sigma tie]*n => moving lower upper",
            g.lineLiquidationPrices,
            150
        );
        _append("liquidation_prices", g.extremeLiquidationPrices());
        // Last, so every file above keeps its draws
        _generate(
            "fee_ledger",
            "n [kind a b c]*n (0 accrue amount, 1 mint account n, 2 burn account n, 3 collect account, 4 seize src dst n; unused fields 0) => per step: - | paid | err (ends it); then | growth held pending; per account: units mark owed",
            g.lineFeeLedger,
            500
        );
    }

    function _append(string memory name, string[] memory lines) internal {
        string memory path = string.concat(DIR, name, ".txt");
        for (uint256 i; i < lines.length; ++i) {
            vm.writeLine(path, lines[i]);
        }
    }

    /*  ================================================
                             Driver
        ================================================  */

    /// @dev One external call per line keeps memory from growing over thousands of lines
    function _generate(
        string memory name,
        string memory format,
        function() external returns (string memory) line,
        uint256 count
    ) internal {
        string memory path = string.concat(DIR, name, ".txt");
        if (vm.exists(path)) vm.removeFile(path);
        vm.writeLine(path, string.concat("# ", format));
        vm.writeLine(path, "# COLLATERAL = sqrtA sqrtB L p0 d0 s0 p1 d1 s1, OTHER = p2 d2 s2, PENALTIES = q0 q1 q2");
        for (uint256 i; i < count; ++i) {
            vm.writeLine(path, line());
        }
    }
}
