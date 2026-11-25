// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {DebtLanes} from "./DebtLanes.sol";
import {MarketLogic} from "./MarketLogic.sol";
import {BorrowableState, Market, Rounding, WAD} from "./Types.sol";

import {ISenzuBorrowable} from "../interfaces/ISenzuBorrowable.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

library BorrowLogic {
    using SafeCastLib for uint256;

    /// @notice The fee on borrowing `assets`, added to the debt and booked to the protocol reserves; rounded up
    function borrowFee(uint256 assets, uint256 feeWad) internal pure returns (uint256) {
        return FixedPointMathLib.fullMulDivUp(assets, feeWad, WAD);
    }

    /// @dev `market` is `asset`'s, as `_accrue` returns it
    function addDebt(
        BorrowableState storage s,
        Market storage market,
        address asset,
        address account,
        uint256 id,
        uint256 assets,
        uint256 fee,
        uint256 totalSupplyShares
    ) internal returns (uint256 shares, uint256 feeShares) {
        if (assets > market.totalSupplyAssets - market.totalBorrowAssets) {
            revert ISenzuBorrowable.SenzuBorrowable__InsufficientCash(asset);
        }
        uint256 debt = assets + fee;

        if (fee > 0) {
            feeShares = MarketLogic.toShares(fee, market.totalSupplyAssets, totalSupplyShares, Rounding.Down);
            market.totalSupplyAssets += fee.toUint128();
        }

        shares = MarketLogic.toShares(debt, market.totalBorrowAssets, market.totalBorrowShares, Rounding.Up);
        market.totalBorrowAssets += debt.toUint128();
        market.totalBorrowShares += shares.toUint128();

        s.debts[account][id] = DebtLanes.add(s.debts[account][id], market.index, shares);
    }

    function sharesOf(BorrowableState storage s, Market storage market, address account, uint256 id)
        internal
        view
        returns (uint256)
    {
        return DebtLanes.sharesOf(s.debts[account][id], market.index);
    }

    function repayAmounts(BorrowableState storage s, Market storage market, address account, uint256 id, uint256 assets)
        internal
        view
        returns (uint256 repaid, uint256 shares)
    {
        uint256 debtShares = sharesOf(s, market, account, id);
        if (debtShares == 0) revert ISenzuBorrowable.SenzuBorrowable__NoDebt();

        uint256 debt = MarketLogic.toAssets(debtShares, market.totalBorrowAssets, market.totalBorrowShares, Rounding.Up);
        if (assets >= debt) return (debt, debtShares);
        if (assets == 0) revert ISenzuBorrowable.SenzuBorrowable__ZeroAmount();

        // Burns only the shares worth the whole wei `assets` clears, so their rounding stays with the repayer (the rest
        // of `assets` goes to lenders) instead of shifting up to a wei onto every other borrower. A payment that clears
        // none burns nothing and never reverts, so a liquidation repaying a wei isn't blocked (audit M-02)
        uint256 borrowed = market.totalBorrowAssets;
        uint256 borrowShares = market.totalBorrowShares;
        uint256 clears = MarketLogic.toAssets(
            MarketLogic.toShares(assets, borrowed, borrowShares, Rounding.Down), borrowed, borrowShares, Rounding.Down
        );
        repaid = assets;
        shares = MarketLogic.toShares(clears, borrowed, borrowShares, Rounding.Up);
    }

    /// @dev Burns `shares` for `paid` assets. The market's debt falls by what the shares were worth, rounded down, and
    ///      lenders get the rest: booking the rounded-up `paid` let 1-share debts empty the market's debt while shares
    ///      were left, and the next borrow minted shares without limit (audit H-01). The last shares take all the
    ///      debt, so none is left that no one owes (the virtual shares' part, a wei or so, which lenders lose)
    function repay(
        BorrowableState storage s,
        Market storage market,
        address account,
        uint256 id,
        uint256 paid,
        uint256 shares
    ) internal {
        uint256 booked = shares == market.totalBorrowShares
            ? market.totalBorrowAssets
            : MarketLogic.toAssets(shares, market.totalBorrowAssets, market.totalBorrowShares, Rounding.Down);
        market.totalSupplyAssets = (market.totalSupplyAssets + paid - booked).toUint128();
        reduceDebt(s, market, account, id, booked, shares);
    }

    function reduceDebt(
        BorrowableState storage s,
        Market storage market,
        address account,
        uint256 id,
        uint256 assets,
        uint256 shares
    ) internal {
        market.totalBorrowShares -= shares.toUint128();
        market.totalBorrowAssets -= assets.toUint128();
        s.debts[account][id] = DebtLanes.sub(s.debts[account][id], market.index, shares);
    }
}
