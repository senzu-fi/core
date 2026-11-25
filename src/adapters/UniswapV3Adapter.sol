// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISenzuAdapter} from "../interfaces/ISenzuAdapter.sol";
import {ISenzuERC6909} from "../interfaces/ISenzuERC6909.sol";
import {ISenzuRangeAdapter} from "../interfaces/ISenzuRangeAdapter.sol";
import {RangeAmounts} from "../libraries/RangeAmounts.sol";
import {Holdings, Shape} from "../libraries/Types.sol";
import {LiquidityAmounts} from "../libraries/uniswap/LiquidityAmounts.sol";
import {PoolAddress} from "../libraries/uniswap/PoolAddress.sol";
import {BaseAdapter} from "./BaseAdapter.sol";
import {FeeLedger} from "./FeeLedger.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/**
 *  @title  UniswapV3Adapter
 *  @author Senzu
 *  @notice Uniswap v3 liquidity held in the pools directly, one pool position per range; each `lpId` owns a share of
 *          it. `deposit` data: abi.encode(MintData), minted with the tokens sent to the adapter first, the rest
 *          refunded to `refundTo`. Pool rounding can leave a range's fees a few wei under its holders' sum:
 *          `collectFees` returns what the pool paid. Liquidity anyone else adds to the adapter's range (the pool takes
 *          any owner) belongs to no position.
 */
contract UniswapV3Adapter is FeeLedger, ISenzuRangeAdapter {
    using SafeCastLib for uint256;
    using SafeTransferLib for address;

    /*  ================================================
                             TYPES
        ================================================  */

    /// @notice `liquidity`: exactly this much; 0: as much as the tokens sent make at the pool price
    struct MintData {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
    }

    struct Position {
        address pool;
        int24 tickLower;
        int24 tickUpper;
    }

    struct PoolTokens {
        address token0;
        address token1;
    }

    error UniswapV3Adapter__NotPool();

    /*  ================================================
                             STATE
        ================================================  */

    /// @notice Uniswap v3 factory
    address public immutable factory;

    /// @notice Senzu positions by lpId
    mapping(uint256 lpId => Position) public positions;

    /// @notice Pool tokens cached once per pool on its first deposit
    mapping(address pool => PoolTokens) public poolTokens;

    address internal transient _minting;

    /*  ================================================
                          CONSTRUCTOR
        ================================================  */

    constructor(address collateral_, address factory_) FeeLedger(collateral_) {
        factory = factory_;
    }

    /*  ================================================
                            DEPOSITS
        ================================================  */

    /// @inheritdoc ISenzuAdapter
    function deposit(uint256 lpId, address to, address refundTo, bytes calldata data)
        external
        override
        onlyCollateral
        returns (uint256 liquidity, address token0, address token1, uint256 used0, uint256 used1)
    {
        MintData memory d = abi.decode(data, (MintData));
        (token0, token1) = (d.token0, d.token1);

        IUniswapV3Pool pool = _checkPool(token0, token1, d.fee);
        if (poolTokens[address(pool)].token0 == address(0)) {
            poolTokens[address(pool)] = PoolTokens({token0: token0, token1: token1});
        }
        Position memory p = Position({pool: address(pool), tickLower: d.tickLower, tickUpper: d.tickUpper});
        (liquidity, used0, used1) = _add(pool, token0, token1, p.tickLower, p.tickUpper, d.liquidity, refundTo);
        if (liquidity == 0) revert SenzuAdapter__NoLiquidity();

        positions[lpId] = p;
        // Every position on a range shares the adapter's pool position, whose record the mint just set to the range's
        // fee growth inside: one read instead of `_feeGrowthInside`'s five
        (, uint256 growth0, uint256 growth1,,) = pool.positions(_rangeKey(p));
        _checkpoint(to, lpId, 0, growth0, growth1);
    }

    /// @inheritdoc ISenzuAdapter
    function increaseLiquidity(uint256 lpId, address account, uint256 balance, address refundTo, bytes calldata)
        external
        override
        onlyCollateral
        returns (uint256 liquidityAdded, uint256 used0, uint256 used1)
    {
        Position memory p = positions[lpId];
        PoolTokens memory pt = poolTokens[p.pool];
        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        (liquidityAdded, used0, used1) = _add(pool, pt.token0, pt.token1, p.tickLower, p.tickUpper, 0, refundTo);
        if (liquidityAdded == 0) return (0, 0, 0);
        // The mint just set the range's pool position to the current fee growth inside: one read instead of five
        (, uint256 growth0, uint256 growth1,,) = pool.positions(_rangeKey(p));
        _checkpoint(account, lpId, balance, growth0, growth1);
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
        Position memory p = positions[lpId];
        uint128 removed = liquidity.toUint128();
        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        (amount0, amount1) = pool.burn(p.tickLower, p.tickUpper, removed);
        // `pool.burn` updates the range's feeGrowthInsideLast even when the range's liquidity drops to zero
        (, uint256 growth0, uint256 growth1,,) = pool.positions(_rangeKey(p));
        _checkpoint(account, lpId, balance, growth0, growth1);
        // Principal first: the range's fees sit in the pool beside it, so a fee pot a few wei short is the fees'
        // (audit M-01)
        if (amount0 > 0 || amount1 > 0) {
            (amount0, amount1) = pool.collect(to, p.tickLower, p.tickUpper, amount0.toUint128(), amount1.toUint128());
        }
        if (balance == liquidity) _payFeesOwed(account, lpId, account);
    }

    /*  ================================================
                           CALLBACKS
        ================================================  */

    /// @notice Uniswap v3 mint callback; pays only the pool the adapter is minting in
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data) external {
        if (msg.sender != _minting) revert UniswapV3Adapter__NotPool();
        (address token0, address token1, uint256 balance0, uint256 balance1) =
            abi.decode(data, (address, address, uint256, uint256));
        if (amount0Owed > balance0 || amount1Owed > balance1) {
            revert SenzuAdapter__Underfunded();
        }
        if (amount0Owed > 0) token0.safeTransfer(msg.sender, amount0Owed);
        if (amount1Owed > 0) token1.safeTransfer(msg.sender, amount1Owed);
    }

    /*  ================================================
                             VIEWS
        ================================================  */

    /// @inheritdoc ISenzuAdapter
    function tokens(uint256 lpId) external view override returns (address, address) {
        PoolTokens storage pt = poolTokens[positions[lpId].pool];
        return (pt.token0, pt.token1);
    }

    /// @inheritdoc ISenzuAdapter
    function amountsAt(uint256 lpId, uint256 accountUnits, uint256 totalUnits, uint160[5] calldata sqrtPricesX96)
        external
        view
        override
        returns (uint256[5] memory, uint256[5] memory)
    {
        Position memory p = positions[lpId];
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
        Position memory p = positions[lpId];
        PoolTokens memory pt = poolTokens[p.pool];
        return Shape({
            token0: pt.token0,
            token1: pt.token1,
            sqrtPaX96: TickMath.getSqrtPriceAtTick(p.tickLower),
            sqrtPbX96: TickMath.getSqrtPriceAtTick(p.tickUpper),
            liquidity: ISenzuERC6909(collateral).totalSupply(lpId).toUint128()
        });
    }

    /// @inheritdoc ISenzuAdapter
    function units(uint256 lpId) public view override returns (uint256) {
        return ISenzuERC6909(collateral).totalSupply(lpId);
    }

    /// @inheritdoc ISenzuAdapter
    function poolId(uint256 lpId) external view override returns (bytes32) {
        return bytes32(uint256(uint160(positions[lpId].pool)));
    }

    /// @inheritdoc ISenzuAdapter
    function poolSqrtPriceX96(uint256 lpId) external view override returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,,,,) = IUniswapV3Pool(positions[lpId].pool).slot0();
    }

    /// @inheritdoc ISenzuAdapter
    function quoteDeposit(bytes calldata data)
        external
        view
        override(ISenzuAdapter, BaseAdapter)
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        MintData memory d = abi.decode(data, (MintData));
        if (d.liquidity == 0) revert SenzuAdapter__NoExactDeposit();
        (uint160 sqrtPriceX96,,,,,,) = _checkPool(d.token0, d.token1, d.fee).slot0();
        (amount0, amount1) = LiquidityAmounts.mintAmountsAtTicks(sqrtPriceX96, d.tickLower, d.tickUpper, d.liquidity);
        (token0, token1) = (d.token0, d.token1);
    }

    /*  ================================================
                            INTERNAL
        ================================================  */

    /// @dev The pool's Tick.getFeeGrowthInside, whose arithmetic must wrap
    function _feeGrowthInside(Position memory p) internal view returns (uint256 inside0, uint256 inside1) {
        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        (, int24 tick,,,,,) = pool.slot0();
        (,, uint256 lower0, uint256 lower1,,,,) = pool.ticks(p.tickLower);
        (,, uint256 upper0, uint256 upper1,,,,) = pool.ticks(p.tickUpper);
        uint256 global0 = pool.feeGrowthGlobal0X128();
        uint256 global1 = pool.feeGrowthGlobal1X128();

        unchecked {
            uint256 below0 = tick >= p.tickLower ? lower0 : global0 - lower0;
            uint256 below1 = tick >= p.tickLower ? lower1 : global1 - lower1;
            uint256 above0 = tick < p.tickUpper ? upper0 : global0 - upper0;
            uint256 above1 = tick < p.tickUpper ? upper1 : global1 - upper1;
            inside0 = global0 - below0 - above0;
            inside1 = global1 - below1 - above1;
        }
    }

    /// @dev The key of the adapter's own position on the range, in the pool's `positions`
    function _rangeKey(Position memory p) private view returns (bytes32) {
        return keccak256(abi.encodePacked(address(this), p.tickLower, p.tickUpper));
    }

    /// @dev The factory's pool for sorted tokens and one of its fee tiers: any other address has no code
    function _checkPool(address token0, address token1, uint24 fee) internal view returns (IUniswapV3Pool pool) {
        pool = IUniswapV3Pool(PoolAddress.compute(factory, token0, token1, fee));
        if (address(pool).code.length == 0) revert SenzuAdapter__UnsupportedPool();
    }

    function _previewGrowth(uint256 lpId) internal view override returns (uint256, uint256) {
        return _feeGrowthInside(positions[lpId]);
    }

    /// @dev Pokes the pool's range position with a zero burn (when it has liquidity) so one `positions` read gives the
    ///      exact fee growth inside and credits the pool's `tokensOwed` for the collect that follows
    function _pokeGrowth(uint256 lpId) internal override returns (uint256 growth0, uint256 growth1) {
        Position memory p = positions[lpId];
        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        bytes32 key = _rangeKey(p);
        (uint128 rangeLiquidity, uint256 g0, uint256 g1,,) = pool.positions(key);
        if (rangeLiquidity == 0) return (g0, g1);
        pool.burn(p.tickLower, p.tickUpper, 0);
        (, growth0, growth1,,) = pool.positions(key);
    }

    function _sendFees(uint256 lpId, address to, uint128 amount0, uint128 amount1)
        internal
        override
        returns (uint256 paid0, uint256 paid1)
    {
        Position memory p = positions[lpId];
        return IUniswapV3Pool(p.pool).collect(to, p.tickLower, p.tickUpper, amount0, amount1);
    }

    /// @dev Collects directly from the pool to the holder first and the protocol cut second, so a pot a few wei short
    ///      takes from the cut before the holder (and skips bouncing through the adapter)
    function _sendFeesAndCut(
        uint256 lpId,
        address to,
        uint128 amount0,
        uint128 amount1,
        address feeTo,
        uint128 cut0,
        uint128 cut1
    ) internal override returns (uint256 paid0, uint256 paid1, uint256 paidCut0, uint256 paidCut1) {
        Position memory p = positions[lpId];
        IUniswapV3Pool pool = IUniswapV3Pool(p.pool);
        if (amount0 > 0 || amount1 > 0) {
            (paid0, paid1) = pool.collect(to, p.tickLower, p.tickUpper, amount0, amount1);
        }
        if (cut0 > 0 || cut1 > 0) {
            (paidCut0, paidCut1) = pool.collect(feeTo, p.tickLower, p.tickUpper, cut0, cut1);
        }
    }

    function _add(
        IUniswapV3Pool pool,
        address token0,
        address token1,
        int24 tickLower,
        int24 tickUpper,
        uint128 exact,
        address refundTo
    ) private returns (uint128 liquidity, uint256 used0, uint256 used1) {
        uint256 balance0 = token0.balanceOf(address(this));
        uint256 balance1 = token1.balanceOf(address(this));
        liquidity = exact;
        if (liquidity == 0) {
            (uint160 sqrtPriceX96,,,,,,) = pool.slot0();
            liquidity = LiquidityAmounts.liquidityAtTicks(sqrtPriceX96, tickLower, tickUpper, balance0, balance1);
        }

        if (liquidity > 0) {
            // forge-lint: disable-next-line(missing-events-access-control)
            _minting = address(pool);
            (used0, used1) = pool.mint(
                address(this), tickLower, tickUpper, liquidity, abi.encode(token0, token1, balance0, balance1)
            );
            _minting = address(0);
        }

        _sendPair(token0, token1, balance0 - used0, balance1 - used1, refundTo);
    }
}
