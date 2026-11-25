// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Market} from "../libraries/Types.sol";
import {ISenzuCollateral} from "./ISenzuCollateral.sol";
import {ISenzuCore} from "./ISenzuCore.sol";

/**
 *  @title  ISenzuBorrowable
 *  @author Senzu
 *  @notice Lenders' side of one Senzu deployment: lending markets (one per asset, lender shares are ERC-6909 ids
 *          with `id = uint160(asset)`) and the debt of collateral positions. Only its paired SenzuCollateral can
 *          open, move or write off debt; anyone can supply, withdraw and repay.
 */
interface ISenzuBorrowable is ISenzuCore {
    /// @custom:error NotCollateral Reverts when a collateral-only function is called by any other address
    error SenzuBorrowable__NotCollateral();

    /// @custom:error ZeroAmount Reverts on a zero asset/share input or when a share/asset conversion rounds to zero
    error SenzuBorrowable__ZeroAmount();

    /**
     *  @custom:error MarketAlreadyExists Reverts when `createMarket` is called for an asset that already has a market
     *  @param asset The already-listed market asset
     */
    error SenzuBorrowable__MarketAlreadyExists(address asset);

    /// @custom:error MarketNotFound Reverts when accessing a non-existent market
    error SenzuBorrowable__MarketNotFound(address asset);

    /// @custom:error IndexOutOfBounds Reverts when `marketAt` is given an index past the last market
    error SenzuBorrowable__IndexOutOfBounds(uint256 index);

    /// @custom:error TooManyMarkets Reverts when `createMarket` is called after `MAX_MARKETS` (256) markets exist
    error SenzuBorrowable__TooManyMarkets();

    /**
     *  @custom:error NoOracleFeed Reverts when `createMarket` is called for an asset with no configured oracle feed
     *  @param asset The asset missing an oracle feed
     */
    error SenzuBorrowable__NoOracleFeed(address asset);

    /**
     *  @custom:error InsufficientCash Reverts when `withdraw` or `borrow` exceeds available market cash
     *  @param asset The market asset lacking liquidity
     */
    error SenzuBorrowable__InsufficientCash(address asset);

    /// @custom:error InvalidReserveFactor Reverts when `reserveFactorWad` exceeds the 50% maximum
    error SenzuBorrowable__InvalidReserveFactor();

    /// @custom:error TooManyDebts Reverts when a borrow would give a position debt in more than two distinct markets
    error SenzuBorrowable__TooManyDebts();

    /// @custom:error DebtTooLarge Reverts when a position's borrow shares in one market reach or exceed `2^119`
    error SenzuBorrowable__DebtTooLarge();

    /// @custom:error NoDebt Reverts when `repay`, `repayFor`, or `writeOff` targets a position with no debt
    error SenzuBorrowable__NoDebt();

    /**
     *  @custom:error UnsupportedToken Reverts when pulling `asset` delivers fewer tokens than expected
     *                (fee-on-transfer token)
     *  @param asset The unsupported token
     */
    error SenzuBorrowable__UnsupportedToken(address asset);

    /**
     *  @notice Emitted when a new lending market is created
     *  @param asset Underlying ERC-20 token of the market
     *  @param index Dense market index (`0..255`) used in position debt lanes
     *  @param reserveFactorWad Share of accrued interest allocated to protocol reserves (1e18 = 100%)
     */
    event MarketCreated(address indexed asset, uint8 index, uint64 reserveFactorWad);

    /**
     *  @notice Emitted when a market's reserve factor is updated
     *  @param asset Market underlying token
     *  @param reserveFactorWad New reserve factor (1e18 = 100%)
     */
    event MarketReserveFactorSet(address indexed asset, uint64 reserveFactorWad);

    /**
     *  @notice Emitted when non-zero interest accrues on a market
     *  @dev `rateAtTarget` is per second (1e18 = 100%) after accrual. Emitted only when `interest > 0`: between
     *       events the rate at target follows from the market's utilization (an empty market's doesn't move)
     *  @param asset Market underlying token
     *  @param interest Interest accrued in underlying asset units
     *  @param reserveShares Lender shares booked to protocol reserves for this accrual
     *  @param totalBorrowAssets Total market borrow assets after accrual
     *  @param rateAtTarget Updated rate at target utilization, per second (1e18 = 100%)
     */
    event AccrueInterest(
        address indexed asset, uint256 interest, uint256 reserveShares, uint256 totalBorrowAssets, uint256 rateAtTarget
    );

    /**
     *  @notice Emitted when a lender supplies assets to a market
     *  @param to Recipient of the minted lender shares
     *  @param asset Market underlying token
     *  @param assets Amount of `asset` supplied
     *  @param shares Lender shares minted to `to`
     */
    event Supply(address indexed to, address indexed asset, uint256 assets, uint256 shares);

    /**
     *  @notice Emitted when lender shares are redeemed for underlying assets
     *  @param receiver Recipient of the withdrawn underlying tokens
     *  @param owner Account whose lender shares were burned
     *  @param asset Market underlying token
     *  @param assets Amount of `asset` sent to `receiver`
     *  @param shares Lender shares burned from `owner`
     */
    event Withdraw(
        address indexed receiver, address indexed owner, address indexed asset, uint256 assets, uint256 shares
    );

    /**
     *  @notice Emitted when a collateral position borrows from a market
     *  @param account Position holder taking on the debt
     *  @param id Collateral position id
     *  @param asset Market underlying token borrowed
     *  @param to Recipient of the borrowed tokens
     *  @param assets Principal sent to `to`
     *  @param shares Borrow shares minted for `assets + fee`
     *  @param fee Opening fee added to the debt on top of `assets` (0 without one), booked to reserves as `feeShares`
     *  @param feeShares Lender shares booked to protocol reserves for `fee`
     */
    event Borrow(
        address indexed account,
        uint256 indexed id,
        address indexed asset,
        address to,
        uint256 assets,
        uint256 shares,
        uint256 fee,
        uint256 feeShares
    );

    /**
     *  @notice Emitted when debt on a position is repaid
     *  @param account Position holder whose debt was reduced
     *  @param id Collateral position id
     *  @param asset Debt asset repaid
     *  @param assets Amount of `asset` repaid
     *  @param shares Borrow shares burned
     */
    event Repay(address indexed account, uint256 indexed id, address indexed asset, uint256 assets, uint256 shares);

    /**
     *  @notice Emitted when unbacked debt is written off and socialized across a market's lenders
     *  @param account Position holder whose debt was written off
     *  @param id Collateral position id
     *  @param asset Market underlying token
     *  @param badDebtAssets Amount of debt socialized across lenders
     */
    event BadDebt(address indexed account, uint256 indexed id, address indexed asset, uint256 badDebtAssets);

    /// @notice The only contract allowed to open, move or write off debt; fixed at construction
    /// @return The paired collateral contract
    function collateral() external view returns (ISenzuCollateral);

    /// @notice Stored market state as of its last accrual
    /// @param asset Market underlying token
    /// @return Stored `Market` struct (zeroed if the market does not exist)
    function getMarket(address asset) external view returns (Market memory);

    /// @notice Market asset at `index` in creation order
    /// @param index Market index (`0 .. marketsLength() - 1`)
    /// @return asset Underlying token address
    function marketAt(uint256 index) external view returns (address asset);

    /// @notice Total number of created lending markets
    /// @return Count of markets
    function marketsLength() external view returns (uint256);

    /**
     *  @notice Converts supply shares to underlying assets, with interest accrued in view
     *  @param asset Market underlying token
     *  @param shares Lender share amount
     *  @return assets Equivalent asset amount, rounded down
     */
    function convertToAssets(address asset, uint256 shares) external view returns (uint256 assets);

    /**
     *  @notice Converts underlying assets to supply shares, with interest accrued in view
     *  @param asset Market underlying token
     *  @param assets Underlying asset amount
     *  @return shares Equivalent lender share amount, rounded down
     */
    function convertToShares(address asset, uint256 assets) external view returns (uint256 shares);

    /**
     *  @notice Maximum underlying assets `owner` can withdraw right now, capped by available market cash
     *  @param asset Market underlying token
     *  @param owner Lender account
     *  @return assets Withdrawable asset amount
     */
    function maxWithdraw(address asset, address owner) external view returns (uint256 assets);

    /**
     *  @notice Market state accrued to the current block timestamp in view
     *  @dev Rates are instantaneous per-second WAD values (`1e18 = 100%`; multiply by `365 days` for APR). The next
     *       accrual charges the exact integral of the rate as it adapts from here, compounded
     *  @param asset Market underlying token
     *  @return supplyAssets Total supplied assets after view accrual
     *  @return borrowAssets Total borrowed assets after view accrual
     *  @return utilizationWad Current utilization (`borrowAssets / supplyAssets`, 1e18 = 100%)
     *  @return borrowRateWad Instantaneous borrow rate per second (1e18 = 100%)
     *  @return supplyRateWad Instantaneous net supply rate per second (1e18 = 100%)
     *  @return rateAtTargetWad Curve's rate at 90% target utilization, per second (1e18 = 100%)
     */
    function marketState(address asset)
        external
        view
        returns (
            uint256 supplyAssets,
            uint256 borrowAssets,
            uint256 utilizationWad,
            uint256 borrowRateWad,
            uint256 supplyRateWad,
            uint256 rateAtTargetWad
        );

    /**
     *  @notice The (at most two) debts of position `(account, id)`, interest accrued in view, rounded up
     *  @dev An empty slot has `address(0)` and `0`; the second slot is always empty when the first is. Read once per
     *       health check
     *  @param account Position holder
     *  @param id Collateral position id
     *  @return asset0 First debt asset (`address(0)` if debt-free)
     *  @return amount0 Debt owed in `asset0`, rounded up
     *  @return asset1 Second debt asset (`address(0)` if at most one debt)
     *  @return amount1 Debt owed in `asset1`, rounded up
     */
    function debts(address account, uint256 id)
        external
        view
        returns (address asset0, uint256 amount0, address asset1, uint256 amount1);

    /**
     *  @notice Debt of `(account, id)` in one market, interest accrued in view, rounded up
     *  @param account Position holder
     *  @param id Collateral position id
     *  @param asset Market underlying token
     *  @return assets Debt owed in `asset` (0 if the market doesn't exist or the position owes none)
     */
    function debtOf(address account, uint256 id, address asset) external view returns (uint256 assets);

    /**
     *  @notice Borrow shares of `(account, id)` in one market
     *  @param account Position holder
     *  @param id Collateral position id
     *  @param asset Market underlying token
     *  @return shares Borrow share balance (0 if the market doesn't exist or the position owes none)
     */
    function borrowSharesOf(address account, uint256 id, address asset) external view returns (uint256 shares);

    /**
     *  @notice Whether `(account, id)` owes any debt across any market
     *  @param account Position holder
     *  @param id Collateral position id
     *  @return True if the position has at least one non-empty debt lane
     */
    function hasDebt(address account, uint256 id) external view returns (bool);

    /**
     *  @notice Creates the lending market for `asset`
     *  @dev Admin only. Requires an oracle feed for `asset`. Rebasing tokens are unsupported; fee-on-transfer tokens
     *       are rejected on every supply and repay. Reserve factor is at most 50%. Every market runs MarketLogic's
     *       adaptive curve starting at an 8% annual rate at target
     *  @param asset Underlying ERC-20 token for the new market
     *  @param reserveFactorWad Share of accrued interest allocated to protocol reserves (1e18 = 100%, max 0.5e18)
     */
    function createMarket(address asset, uint64 reserveFactorWad) external;

    /**
     *  @notice Updates a market's reserve factor
     *  @dev Admin only (timelock). Accrues interest first so interest earned before the change keeps the previous split
     *  @param asset Market underlying token
     *  @param reserveFactorWad New reserve factor (1e18 = 100%, max 0.5e18)
     */
    function setReserveFactor(address asset, uint64 reserveFactorWad) external;

    /**
     *  @notice Accrues pending interest on `asset`'s market to the current block timestamp
     *  @param asset Market underlying token
     */
    function accrueInterest(address asset) external;

    /**
     *  @notice Mints the protocol's pending lender shares of `asset` (`Market.pendingReserveShares`) to
     *          `factory.protocolReserves()`
     *  @dev Anyone may call it; changes no share price, only where the already-counted reserve shares are held
     *  @param asset Market underlying token
     *  @return shares Lender shares minted to `protocolReserves` (0 if none pending or market doesn't exist)
     */
    function mintReserves(address asset) external returns (uint256 shares);

    /**
     *  @notice Supplies `assets` of `asset` to its market and mints ERC-6909 lender shares to `to`
     *  @dev Pulls exact `assets` from `msg.sender`. Reverts while `ACTION_SUPPLY` is paused
     *  @param asset Market underlying token
     *  @param assets Amount of `asset` to supply
     *  @param to Recipient of the minted lender shares (`id = uint160(asset)`)
     *  @return shares Lender shares minted to `to`
     */
    function supply(address asset, uint256 assets, address to) external returns (uint256 shares);

    /**
     *  @notice Burns `shares` of `owner`'s lender shares in `asset` and sends the underlying tokens to `receiver`
     *  @dev Requires `msg.sender` to be `owner`, an ERC-6909 operator of `owner`, or have sufficient share allowance
     *  @param asset Market underlying token
     *  @param shares Lender shares to burn
     *  @param receiver Recipient of the withdrawn underlying tokens
     *  @param owner Account whose lender shares are burned
     *  @return assets Amount of `asset` transferred to `receiver`
     */
    function withdraw(address asset, uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /**
     *  @notice Repays up to `assets` of `(account, id)`'s debt in `asset`, pulling tokens from `msg.sender`
     *  @dev Anyone can repay any position's debt; passing `type(uint256).max` repays the full debt
     *  @param account Position holder whose debt is repaid
     *  @param id Collateral position id
     *  @param asset Debt asset to repay
     *  @param assets Maximum amount of `asset` to repay (`type(uint256).max` for all)
     *  @return repaid Exact amount of `asset` pulled from `msg.sender` and applied to the debt
     */
    function repay(address account, uint256 id, address asset, uint256 assets) external returns (uint256 repaid);

    /**
     *  @notice Lends `assets` of `asset` to position `(account, id)` and transfers them to `to`
     *  @dev Collateral only. Reverts while `ACTION_BORROW` is paused or if the market lacks cash
     *  @param account Position holder taking on the debt
     *  @param id Collateral position id
     *  @param asset Market underlying token to borrow
     *  @param assets Principal amount transferred to `to`
     *  @param to Recipient of the borrowed tokens
     *  @return shares Borrow shares minted (for `assets` plus any opening fee)
     */
    function borrow(address account, uint256 id, address asset, uint256 assets, address to)
        external
        returns (uint256 shares);

    /**
     *  @notice Books a liquidation's repayment of `(account, id)`'s `asset` debt and any protocol fee without pulling
     *          tokens yet
     *  @dev Collateral only. `fee` enters the market as supply with its lender shares booked to protocol reserves.
     *       Tokens (`repaid + fee`) are collected later via `collectRepayment` before the collateral's lock ends
     *  @param account Position holder whose debt is reduced
     *  @param id Collateral position id
     *  @param asset Debt asset being repaid
     *  @param assets Amount of `asset` to repay
     *  @param fee Protocol liquidation fee in `asset` (0 on write-off or when fee is zero)
     *  @return repaid Actual debt amount booked
     */
    function repayFor(address account, uint256 id, address asset, uint256 assets, uint256 fee)
        external
        returns (uint256 repaid);

    /**
     *  @notice Pulls `assets` of `asset` from `payer` to settle liquidation repayments previously booked via `repayFor`
     *  @dev Collateral only
     *  @param payer Lock holder supplying the repayment tokens
     *  @param asset Debt asset being settled
     *  @param assets Exact amount of `asset` to pull from `payer`
     */
    function collectRepayment(address payer, address asset, uint256 assets) external;

    /**
     *  @notice Writes off every remaining debt of `(account, id)`, socializing the loss across each market's lenders
     *  @dev Collateral only
     *  @param account Position holder whose remaining debts are written off
     *  @param id Collateral position id
     */
    function writeOff(address account, uint256 id) external;
}
