// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuRangeAdapter} from "../interfaces/ISenzuRangeAdapter.sol";
import {RangeAmounts} from "../libraries/RangeAmounts.sol";
import {Holdings, Shape} from "../libraries/Types.sol";
import {LiquidityAmounts} from "../libraries/uniswap/LiquidityAmounts.sol";
import {UniswapV4State} from "../libraries/uniswap/UniswapV4State.sol";
import {BaseAdapter} from "./BaseAdapter.sol";
import {HeldFeesAdapter} from "./HeldFeesAdapter.sol";
import {PoolRegistry} from "./PoolRegistry.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  UniswapV4Adapter
 *  @author Senzu
 *  @notice Uniswap v4 liquidity held in the PoolManager directly, one pool position per `lpId` (its salt). Hookless
 *          pools only. `deposit` data: abi.encode(MintData), minted with the tokens sent to the adapter first, the rest
 *          refunded to `refundTo`. Native ETH is reported, paid and taken as WETH. v4 credits a position's fees on
 *          every liquidity change, so the adapter collects and holds them (HeldFeesAdapter).
 */
contract UniswapV4Adapter is HeldFeesAdapter, PoolRegistry, ISenzuRangeAdapter, IUnlockCallback {
    using SafeTransferLib for address;
    using SafeCast for uint256;
    using SafeCast for int128;

    /*  ================================================
                             TYPES
        ================================================  */

    /// @notice `liquidity`: exactly this much; 0: as much as the tokens sent make at the pool price
    struct MintData {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    /// @dev 1 storage slot
    struct Position {
        uint32 poolIndex;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Pool {
        PoolKey key;
        bytes32 id;
    }

    error UniswapV4Adapter__NotPoolManager();

    /*  ================================================
                             STATE
        ================================================  */

    /// @notice Uniswap v4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice WETH, reported for native ETH
    address public immutable weth;

    mapping(uint256 lpId => Position) internal _positions;

    mapping(uint32 poolIndex => Pool) internal _pools;

    /*  ================================================
                          CONSTRUCTOR
        ================================================  */

    constructor(address collateral_, address poolManager_, address weth_) HeldFeesAdapter(collateral_) {
        poolManager = IPoolManager(poolManager_);
        weth = weth_;
    }

    /*  ================================================
                            DEPOSITS
        ================================================  */

    /// @inheritdoc ISenzuAdapter
    function deposit(uint256 lpId, address, address refundTo, bytes calldata data)
        external
        override
        onlyCollateral
        returns (uint256 liquidity, address token0, address token1, uint256 used0, uint256 used1)
    {
        MintData memory d = abi.decode(data, (MintData));
        PoolKey memory key = d.poolKey;
        _checkPool(key);

        bytes32 poolId = PoolId.unwrap(key.toId());
        (uint32 poolIndex, bool isNew) = _registerPool(poolId);
        if (isNew) _pools[poolIndex] = Pool({key: key, id: poolId});

        uint128 minted;
        (minted, used0, used1) = _add(lpId, key, poolId, d.tickLower, d.tickUpper, 0, d.liquidity, refundTo);
        if (minted == 0) revert SenzuAdapter__NoLiquidity();

        _positions[lpId] =
            Position({poolIndex: poolIndex, tickLower: d.tickLower, tickUpper: d.tickUpper, liquidity: minted});

        liquidity = minted;
        (token0, token1) = _pairOf(key);
    }

    /// @inheritdoc ISenzuAdapter
    function increaseLiquidity(uint256 lpId, address account, uint256 balance, address refundTo, bytes calldata)
        external
        override
        onlyCollateral
        returns (uint256 liquidityAdded, uint256 used0, uint256 used1)
    {
        Position memory p = _positions[lpId];
        PoolKey memory key = _pools[p.poolIndex].key;
        bytes32 poolId = _pools[p.poolIndex].id;
        // The add books the fees accrued, at the liquidity before it
        (liquidityAdded, used0, used1) = _add(lpId, key, poolId, p.tickLower, p.tickUpper, p.liquidity, 0, refundTo);
        _checkpointHeld(account, lpId, balance);
        _positions[lpId].liquidity = p.liquidity + liquidityAdded.toUint128();
    }

    /// @inheritdoc ISenzuAdapter
    function decreaseLiquidity(
        uint256 lpId,
        uint256 liquidity,
        address account,
        uint256 balance,
        address to,
        bytes calldata
    ) external override onlyCollateral returns (uint256 amount0, uint256 amount1) {
        Position memory p = _positions[lpId];
        PoolKey memory key = _pools[p.poolIndex].key;
        uint128 removed = liquidity.toUint128();
        // The removal books the fees accrued, at the liquidity before it
        (amount0, amount1) = _remove(lpId, key, p.tickLower, p.tickUpper, p.liquidity, removed, to);
        _checkpointHeld(account, lpId, balance);
        _positions[lpId].liquidity = p.liquidity - removed;
        if (balance == liquidity) _payFeesOwed(account, lpId, account);
    }

    /*  ================================================
                           CALLBACKS
        ================================================  */

    /// @notice Native ETH taken from the PoolManager and from unwrapping WETH
    receive() external payable {}

    /// @notice Uniswap v4 unlock callback, from the PoolManager only
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UniswapV4Adapter__NotPoolManager();
        (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 delta, bytes32 salt, address recipient) =
            abi.decode(data, (PoolKey, int24, int24, int256, bytes32, address));
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            poolManager.modifyLiquidity(key, ModifyLiquidityParams(tickLower, tickUpper, delta, salt), "");

        // A removal pays its principal straight to the recipient; an add or a fee collect settles with the adapter
        if (delta < 0) {
            _takeRemove(key.currency0, callerDelta.amount0(), feesAccrued.amount0(), recipient);
            _takeRemove(key.currency1, callerDelta.amount1(), feesAccrued.amount1(), recipient);
        } else {
            _settle(key.currency0, callerDelta.amount0());
            _settle(key.currency1, callerDelta.amount1());
        }
        return abi.encode(callerDelta, feesAccrued);
    }

    /*  ================================================
                             VIEWS
        ================================================  */

    /// @notice A position with its pool
    function positions(uint256 lpId)
        external
        view
        returns (PoolKey memory poolKey, bytes32 poolId, int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        Position memory p = _positions[lpId];
        poolKey = _pools[p.poolIndex].key;
        poolId = _pools[p.poolIndex].id;
        tickLower = p.tickLower;
        tickUpper = p.tickUpper;
        liquidity = p.liquidity;
    }

    /// @inheritdoc ISenzuAdapter
    function tokens(uint256 lpId) external view override returns (address, address) {
        return _tokens(lpId);
    }

    /// @inheritdoc ISenzuAdapter
    function amountsAt(uint256 lpId, uint256 accountUnits, uint256 totalUnits, uint160[5] calldata sqrtPricesX96)
        external
        view
        override
        returns (uint256[5] memory, uint256[5] memory)
    {
        Position memory p = _positions[lpId];
        Holdings memory h = RangeAmounts.at(
            TickMath.getSqrtPriceAtTick(p.tickLower),
            TickMath.getSqrtPriceAtTick(p.tickUpper),
            totalUnits == 0 ? 0 : accountUnits.toUint128(),
            sqrtPricesX96
        );
        return (h.amounts0, h.amounts1);
    }

    /// @inheritdoc ISenzuRangeAdapter
    function shape(uint256 lpId) public view override returns (Shape memory) {
        Position memory p = _positions[lpId];
        PoolKey storage key = _pools[p.poolIndex].key;
        return Shape({
            token0: _token(key.currency0),
            token1: Currency.unwrap(key.currency1),
            sqrtPaX96: TickMath.getSqrtPriceAtTick(p.tickLower),
            sqrtPbX96: TickMath.getSqrtPriceAtTick(p.tickUpper),
            liquidity: p.liquidity
        });
    }

    /// @inheritdoc ISenzuAdapter
    /// @dev Read from the PoolManager, not the adapter's own count
    function units(uint256 lpId) public view override returns (uint256) {
        Position memory p = _positions[lpId];
        if (p.poolIndex == 0) return 0;
        return UniswapV4State.positionLiquidity(
            poolManager, _pools[p.poolIndex].id, address(this), p.tickLower, p.tickUpper, bytes32(lpId)
        );
    }

    /// @inheritdoc ISenzuAdapter
    function poolId(uint256 lpId) external view override returns (bytes32) {
        return _pools[_positions[lpId].poolIndex].id;
    }

    /// @inheritdoc ISenzuAdapter
    function poolSqrtPriceX96(uint256 lpId) public view override returns (uint160 sqrtPriceX96) {
        sqrtPriceX96 = UniswapV4State.sqrtPriceX96(poolManager, _pools[_positions[lpId].poolIndex].id);
    }

    /// @inheritdoc ISenzuAdapter
    function quoteDeposit(bytes calldata data)
        external
        view
        override(ISenzuAdapter, BaseAdapter)
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        MintData memory d = abi.decode(data, (MintData));
        _checkPool(d.poolKey);
        if (d.liquidity == 0) revert SenzuAdapter__NoExactDeposit();
        uint160 sqrtPriceX96 = UniswapV4State.sqrtPriceX96(poolManager, PoolId.unwrap(d.poolKey.toId()));
        (amount0, amount1) = LiquidityAmounts.mintAmountsAtTicks(sqrtPriceX96, d.tickLower, d.tickUpper, d.liquidity);
        (token0, token1) = _pairOf(d.poolKey);
    }

    /*  ================================================
                            INTERNAL
        ================================================  */

    function _pendingFees(uint256 lpId) internal view override returns (uint256, uint256, uint256) {
        Position memory p = _positions[lpId];
        if (p.liquidity == 0) return (0, 0, 0);
        (uint256 pending0, uint256 pending1) = _accrued(lpId, _pools[p.poolIndex].id, p);
        return (pending0, pending1, p.liquidity);
    }

    function _collectPending(uint256 lpId) internal override {
        Position memory p = _positions[lpId];
        // The PoolManager rejects a zero liquidity change on an empty position
        if (p.liquidity == 0) return;
        bytes32 poolId = _pools[p.poolIndex].id;
        (uint256 pending0, uint256 pending1) = _accrued(lpId, poolId, p);
        if (pending0 > 0 || pending1 > 0) {
            _modify(lpId, _pools[p.poolIndex].key, p.tickLower, p.tickUpper, p.liquidity, 0, address(0));
        }
    }

    /// @dev Sized 1 wei under the amounts sent: v4 rounds up the amounts it takes
    function _add(
        uint256 lpId,
        PoolKey memory key,
        bytes32 poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 existingLiquidity,
        uint128 exact,
        address refundTo
    ) private returns (uint128 liquidity, uint256 used0, uint256 used1) {
        (address token0, address token1) = _pairOf(key);
        uint256 amount0 = _sentIn(token0);
        uint256 amount1 = _sentIn(token1);

        liquidity = exact;
        if (liquidity == 0) {
            uint160 sqrtPriceX96 = UniswapV4State.sqrtPriceX96(poolManager, poolId);
            liquidity = LiquidityAmounts.liquidityAtTicks(
                sqrtPriceX96, tickLower, tickUpper, amount0 > 0 ? amount0 - 1 : 0, amount1 > 0 ? amount1 - 1 : 0
            );
        }

        if (liquidity > 0) {
            (int128 principal0, int128 principal1) =
                _modify(lpId, key, tickLower, tickUpper, existingLiquidity, int256(uint256(liquidity)), address(0));
            (used0, used1) = ((-principal0).toUint128(), (-principal1).toUint128());
        }
        if (used0 > amount0 || used1 > amount1) revert SenzuAdapter__Underfunded();

        _sendPair(token0, token1, amount0 - used0, amount1 - used1, refundTo);
    }

    function _remove(
        uint256 lpId,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 existingLiquidity,
        uint128 liquidity,
        address to
    ) private returns (uint256 amount0, uint256 amount1) {
        (int128 principal0, int128 principal1) = _modify(
            lpId, key, tickLower, tickUpper, existingLiquidity, -int256(uint256(liquidity)), to
        );
        (amount0, amount1) = (principal0.toUint128(), principal1.toUint128());
        // ERC-20 principal was already taken directly to `to` inside `unlockCallback`; only native ETH needed wrapping
        if (key.currency0.isAddressZero() && amount0 > 0) weth.safeTransfer(to, amount0);
    }

    /// @dev v4's callerDelta includes the fees accrued, credited on every liquidity change
    function _modify(
        uint256 lpId,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint128 existingLiquidity,
        int256 delta,
        address recipient
    ) private returns (int128 principal0, int128 principal1) {
        (BalanceDelta callerDelta, BalanceDelta feesAccrued) = abi.decode(
            poolManager.unlock(abi.encode(key, tickLower, tickUpper, delta, bytes32(lpId), recipient)),
            (BalanceDelta, BalanceDelta)
        );
        uint256 fee0 = feesAccrued.amount0().toUint128();
        uint256 fee1 = feesAccrued.amount1().toUint128();
        if ((fee0 > 0 || fee1 > 0) && existingLiquidity > 0) {
            (address token0, address token1) = _pairOf(key);
            _bookFees(lpId, token0, token1, fee0, fee1, existingLiquidity);
        }
        principal0 = callerDelta.amount0() - fee0.toInt128();
        principal1 = callerDelta.amount1() - fee1.toInt128();
    }

    /// @dev Takes ERC-20 principal directly to `recipient` (skipping a bounce through the adapter) and fees to `this`
    function _takeRemove(Currency currency, int128 totalAmount, int128 feeAmount, address recipient) private {
        if (totalAmount <= 0) {
            if (totalAmount < 0) _settle(currency, totalAmount);
            return;
        }
        if (currency.isAddressZero()) {
            uint256 owed = totalAmount.toUint128();
            poolManager.take(currency, address(this), owed);
            // slither-disable-next-line arbitrary-send-eth
            IWETH9(weth).deposit{value: owed}();
            return;
        }
        uint256 fee = feeAmount > 0 ? feeAmount.toUint128() : 0;
        uint256 principal = totalAmount.toUint128() - fee;
        if (principal > 0) poolManager.take(currency, recipient, principal);
        if (fee > 0) poolManager.take(currency, address(this), fee);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = (-amount).toUint128();
            if (currency.isAddressZero()) {
                IWETH9(weth).withdraw(owed);
                poolManager.settle{value: owed}();
            } else {
                poolManager.sync(currency);
                Currency.unwrap(currency).safeTransfer(address(poolManager), owed);
                poolManager.settle();
            }
        } else if (amount > 0) {
            uint256 owed = amount.toUint128();
            poolManager.take(currency, address(this), owed);
            // slither-disable-next-line arbitrary-send-eth
            if (currency.isAddressZero()) IWETH9(weth).deposit{value: owed}();
        }
    }

    /// @dev v4's fee accrual, whose subtraction must wrap
    function _accrued(uint256 lpId, bytes32 poolId, Position memory p)
        private
        view
        returns (uint256 pending0, uint256 pending1)
    {
        (uint256 inside0, uint256 inside1, uint256 last0, uint256 last1) =
            UniswapV4State.positionFees(poolManager, poolId, address(this), p.tickLower, p.tickUpper, bytes32(lpId));
        unchecked {
            pending0 = FullMath.mulDiv(inside0 - last0, p.liquidity, Q128);
            pending1 = FullMath.mulDiv(inside1 - last1, p.liquidity, Q128);
        }
    }

    /// @dev Hookless, and never native ETH paired with WETH (both are reported as WETH)
    function _checkPool(PoolKey memory key) private view {
        if (key.currency1.isAddressZero()) revert SenzuAdapter__UnsupportedPool();
        if (key.currency0.isAddressZero() && Currency.unwrap(key.currency1) == weth) {
            revert SenzuAdapter__UnsupportedPool();
        }
        address hooks = address(key.hooks);
        if (hooks != address(0)) revert SenzuAdapter__HookNotAllowed(hooks);
    }

    function _tokens(uint256 lpId) internal view override returns (address, address) {
        PoolKey storage key = _pools[_positions[lpId].poolIndex].key;
        return (_token(key.currency0), Currency.unwrap(key.currency1));
    }

    /// @dev The pool's two tokens as Senzu reports them: WETH for native ETH
    function _pairOf(PoolKey memory key) private view returns (address, address) {
        return (_token(key.currency0), Currency.unwrap(key.currency1));
    }

    function _token(Currency currency) private view returns (address) {
        return currency.isAddressZero() ? weth : Currency.unwrap(currency);
    }
}
