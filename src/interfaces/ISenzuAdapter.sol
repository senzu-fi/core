// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 *  @title  ISenzuAdapter
 *  @notice Holds the DEX positions of one SenzuCollateral, each a position of one two-token pool. Only that collateral
 *          changes liquidity. Everything else an exchange offers (fees, rewards) is the adapter's own: it counts them
 *          per holder, told of every balance change, and holders collect from it directly. The collateral values a
 *          position by what its units hold at the oracle's price and at the four stress corners (`amountsAt`), so
 *          any pool whose holdings at a price depend on that price alone fits, whatever its curve. `data` on
 *          `deposit`, `increaseLiquidity` and `decreaseLiquidity` is the caller's, passed through the collateral
 *          unread: what an exchange needs beyond the core's arguments (hook data, per-bin amounts).
 */
interface ISenzuAdapter {
    error SenzuAdapter__NotCollateral();
    error SenzuAdapter__UnsupportedPool();
    error SenzuAdapter__HookNotAllowed(address hook);
    /// @notice A deposit that would add no liquidity
    error SenzuAdapter__NoLiquidity();
    /// @notice A deposit of an exact liquidity that costs more than was sent to the adapter
    error SenzuAdapter__Underfunded();
    error SenzuAdapter__NoExactDeposit();
    error SenzuAdapter__Unauthorized();

    /// @notice `fee0`/`fee1` paid to `to`; `cut0`/`cut1` to the protocol (`ISenzuRiskConfig.feeCut`)
    event CollectFees(
        address indexed account,
        uint256 indexed lpId,
        address to,
        uint256 fee0,
        uint256 fee1,
        uint256 cut0,
        uint256 cut1
    );

    /// @notice The only caller allowed to mutate positions (the SenzuCollateral this adapter serves)
    function collateral() external view returns (address);

    /// @notice A position's pool tokens, sorted as the pool sorts them (native ETH as WETH)
    function tokens(uint256 lpId) external view returns (address token0, address token1);

    /// @notice Units a position holds. SenzuCollateral's totalSupply of its id always equals this: read from the DEX
    ///         where only the adapter can change the position, the adapter's own count otherwise. Never called
    ///         on-chain: valuation uses the collateral's count (`amountsAt`)
    function units(uint256 lpId) external view returns (uint256);

    /**
     *  @notice What `accountUnits` of a position (of its `units(lpId)`) would hold if the pool's price were each of
     *          `sqrtPricesX96` (√(token1 per token0) · 2^96), rounded down: the token amounts the health check values
     *          at the oracle's price and its four stress corners. Rules every adapter keeps, since lenders' solvency
     *          rests on them:
     *          - What the position would hold once the pool was traded to that price, from the position's own state
     *            and the pool's invariant (k, the range's L, each bin's liquidity), never from the pool's current
     *            price or reserves, which anyone can move within a transaction.
     *          - A function of the price alone, so the position's value is concave in prices and its worst case is
     *            at a corner. A curve that moves on its own (bins that follow the price, a re-pegging price scale,
     *            ramping weights) breaks the stress test.
     *          - Bounded gas and no revert for a position that exists: liquidations call it.
     *          Fees and rewards owed are never counted (`feesOwed`).
     */
    function amountsAt(uint256 lpId, uint256 accountUnits, uint256 totalUnits, uint160[5] calldata sqrtPricesX96)
        external
        view
        returns (uint256[5] memory amounts0, uint256[5] memory amounts1);

    /// @notice The pool's current price, for views. Never used for valuation
    function poolSqrtPriceX96(uint256 lpId) external view returns (uint160);

    /// @notice The position's pool as its DEX names it, for indexers: the pool's address on v2, v3 and Aero (left-padded),
    ///         its id on v4 and Ekubo. Never used on-chain
    function poolId(uint256 lpId) external view returns (bytes32);

    /// @notice LP fees `account` would be paid from a position now, after the protocol's cut (never collateral)
    function feesOwed(address account, uint256 lpId) external view returns (uint256 fee0, uint256 fee1);

    /**
     *  @notice Mints the DEX position `data` encodes (the adapter's `MintData`) with the tokens already sent to the
     *          adapter, and returns its units and its tokens as `tokens` reports them (native ETH as WETH). No minimum
     *          amounts: the caller checks what went in. Reverts with `SenzuAdapter__UnsupportedPool` for a pool
     *          the adapter doesn't take, `SenzuAdapter__NoLiquidity` when nothing would be added.
     *  @param to The account that gets the units: its fees count from here
     *  @param refundTo Who gets back what the mint didn't use
     */
    function deposit(uint256 lpId, address to, address refundTo, bytes calldata data)
        external
        returns (uint256 units, address token0, address token1, uint256 used0, uint256 used1);

    /// @notice Tokens and amounts a `deposit` of `data` with an exact liquidity takes at the pool's price now, rounded
    ///         as the pool rounds them. Reverts for data without an exact liquidity, or an adapter without exact
    ///         deposits. Where the DEX mints by amounts only (Aero), the liquidity is a target: a deposit mints what the
    ///         amounts sent make at the pool's price then
    function quoteDeposit(bytes calldata data)
        external
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1);

    /// @notice Adds the token0/token1 already sent to the adapter as liquidity to `lpId`, for `account`, and sends
    ///         whatever doesn't fit the position's ratio back to `refundTo`. No minimum amounts: the caller checks
    ///         what went in. Returns 0, everything refunded, when nothing would be added
    /// @param balance The account's units before the increase
    /// @param data The caller's, unread by the collateral: what the exchange needs for an add, empty when nothing
    function increaseLiquidity(uint256 lpId, address account, uint256 balance, address refundTo, bytes calldata data)
        external
        returns (uint256 unitsAdded, uint256 used0, uint256 used1);

    /// @notice Removes `units` of the position, burned from `account`, and sends the tokens to `to`. A redeem of all
    ///         the account's units (`units == balance`) also pays the account itself, never `to`, every fee (and
    ///         reward, where the DEX pays one) it is owed in the position, as `collectFees` pays them: nothing is
    ///         left behind by leaving. A partial one pays none. No minimum amounts: the caller checks what came out
    /// @param balance The account's units before the burn
    /// @param data The caller's, unread by the collateral. Empty data always removes: seized units, the DAO's and an
    ///        automator's redeem with none. No data changes what `units` pay, their share of the position, since
    ///        several accounts can hold units of one position after a seize
    /// @return amount0 The liquidity's token0, without the fees
    /// @return amount1 The liquidity's token1, without the fees
    function decreaseLiquidity(
        uint256 lpId,
        uint256 units,
        address account,
        uint256 balance,
        address to,
        bytes calldata data
    ) external returns (uint256 amount0, uint256 amount1);

    /// @notice Before a seize moves `units` from `from` to `to` (holding `toBalance`): the seized units take what they
    ///         earned and wasn't collected with them, so it is split by units when it is. Books nothing, only reads
    ///         the DEX and never moves a token: a paused token or the DEX's own lock can't block a liquidation
    function seize(uint256 lpId, address from, address to, uint256 toBalance, uint256 units) external;

    /// @notice Pays `account` its fees in a position, to `to`, less the protocol's cut (`ISenzuRiskConfig.feeCut`).
    ///         The account or its operator on the collateral. A v3 position can pay a few wei less than owed: the
    ///         pool rounds a range's fees down at every poke
    function collectFees(address account, uint256 lpId, address to) external returns (uint256 fee0, uint256 fee1);
}
