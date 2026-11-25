// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuLens} from "./ISenzuLens.sol";

/**
 *  @title  ISenzuPreviews
 *  @notice Previews of one deployment: a new position, max leverage, max borrow, the swap that fits a range. Not
 *          deployed: the reference the SDK's off-chain core ports.
 */
interface ISenzuPreviews is ISenzuLens {
    /// @notice `previewOpen` with `borrowAssets` and `borrowAmounts` of different lengths
    error SenzuPreviews__LengthMismatch();

    /// @notice Inputs of the Create Position panel. Prices are the oracle's; a swap is assumed at the oracle price.
    struct OpenParams {
        address token0;
        address token1;
        uint160 sqrtPaX96;
        uint160 sqrtPbX96;
        uint256 deposit0;
        uint256 deposit1;
        address[] borrowAssets;
        uint256[] borrowAmounts;
        bool swap; // false = "Disable swap": only what fits the range's ratio is added
    }

    struct OpenPreview {
        uint128 liquidity;
        uint256 amount0; // in the position
        uint256 amount1;
        uint256 collateralUsdWad;
        uint256 marginUsdWad; // deposits
        uint256 debtUsdWad;
        uint256 leverageWad; // size / margin
        uint256 healthWad;
        bool allowed; // passes the borrow check (health, at most 2 debts, and every debt outside the pair `liquid`)
        LiquidationPrices liquidation;
    }

    /// @notice The swap that turns `amount0`/`amount1` into exactly the range's token ratio
    struct SwapQuote {
        bool zeroForOne; // sell token0 for token1 (false: sell token1 for token0)
        uint256 amountIn;
        uint256 amountOut; // expected at the given price, after the swap fee
    }

    /// @notice Most `asset` (account, id) can borrow now (health with buffer; capped by cash and the borrow cap). 0 for
    ///         an asset outside the pair that isn't `liquid`, and for a third asset when it owes two already
    function maxBorrow(address account, uint256 id, address asset) external view returns (uint256 assets);

    /// @notice Health at the penalty the new position pays: the highest of its pair's tokens and every asset it
    ///         borrows outside the pair (a zero amount is no debt)
    function previewOpen(OpenParams calldata params) external view returns (OpenPreview memory);

    /**
     *  @notice Highest leverage (size / margin, WAD) a new position in this range passes the borrow check with.
     *          `borrowAsset` = address(0) borrows both pair tokens at the range's ratio (no swap); otherwise all debt
     *          is in `borrowAsset` and is swapped into the range (1x if it's outside the pair and not `liquid`).
     */
    function maxLeverage(address token0, address token1, uint160 sqrtPaX96, uint160 sqrtPbX96, address borrowAsset)
        external
        view
        returns (uint256 leverageWad);

    /**
     *  @notice How much to swap so that `amount0`/`amount1` (deposits plus what is borrowed) fit the range's token ratio
     *          exactly, so nothing is refunded when the position is minted or increased. Out of range, the position
     *          holds one token only, so everything of the other token is swapped.
     *  @param sqrtPriceX96 Price the swap executes at (e.g. the pool's); 0 uses the oracle price
     *  @param swapFeeWad Fee taken from the swap input, 1e18 = 100% (e.g. 0.0005e18 for a 0.05% pool)
     */
    function swapForRange(
        address token0,
        address token1,
        uint160 sqrtPaX96,
        uint160 sqrtPbX96,
        uint256 amount0,
        uint256 amount1,
        uint160 sqrtPriceX96,
        uint256 swapFeeWad
    ) external view returns (SwapQuote memory quote);
}
