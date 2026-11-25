// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

contract MockERC20 {
    string public symbol;
    uint8 public immutable decimals;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    uint256 public transferFeeBps; // burned from every transfer, to test fee-on-transfer tokens
    bool public paused; // every transfer reverts, as a stock token paused for a corporate action

    constructor(string memory symbol_, uint8 decimals_) {
        symbol = symbol_;
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function setTransferFee(uint256 bps) external {
        transferFeeBps = bps;
    }

    function setPaused(bool paused_) external {
        paused = paused_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(!paused, "paused");
        uint256 fee = amount * transferFeeBps / 10_000;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
    }
}

/// @dev A Robinhood-style stock token: it can pause its own price around corporate actions
contract MockStock is MockERC20 {
    bool public oraclePaused;

    constructor(string memory symbol_) MockERC20(symbol_, 18) {}

    function setOraclePaused(bool paused) external {
        oraclePaused = paused;
    }
}

/// @dev WETH with deposit/withdraw, etched over the fixture's WETH so its markets and balances stay
contract MockWETH is MockERC20 {
    constructor() MockERC20("WETH", 18) {}

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok);
    }
}

/**
 *  @dev Pyth Core for tests. `set` stores a price as a feed's newest; a price set "live" follows the clock (publishTime
 *       = block.timestamp), as if every transaction posted a fresh update at that price. `updatePriceFeeds` takes
 *       abi.encode(id, price, conf, expo, publishTime) updates and keeps only newer ones, as Core does.
 */
contract MockPyth {
    struct Stored {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
        bool live;
        bool exists;
    }

    error PriceFeedNotFound();

    mapping(bytes32 => Stored) public stored;
    uint256 public feePerUpdate;

    function set(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime, bool live) external {
        stored[id] = Stored(price, conf, expo, publishTime, live, true);
    }

    function setFee(uint256 fee) external {
        feePerUpdate = fee;
    }

    function getPriceUnsafe(bytes32 id) external view returns (PythStructs.Price memory) {
        Stored memory s = stored[id];
        if (!s.exists) revert PriceFeedNotFound();
        return PythStructs.Price(s.price, s.conf, s.expo, s.live ? block.timestamp : s.publishTime);
    }

    function getUpdateFee(bytes[] calldata updates) external view returns (uint256) {
        return feePerUpdate * updates.length;
    }

    function updatePriceFeeds(bytes[] calldata updates) external payable {
        require(msg.value >= feePerUpdate * updates.length, "fee");
        for (uint256 i; i < updates.length; ++i) {
            (bytes32 id, int64 price, uint64 conf, int32 expo, uint256 publishTime) =
                abi.decode(updates[i], (bytes32, int64, uint64, int32, uint256));
            Stored memory s = stored[id];
            if (s.exists && !s.live && s.publishTime >= publishTime) continue;
            stored[id] = Stored(price, conf, expo, publishTime, false, true);
        }
    }
}

contract MockAggregator {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId = 1;
    uint80 public answeredInRound = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        startedAt = block.timestamp;
        updatedAt = block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "MOCK / USD";
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRounds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}

import {BaseAdapter} from "../../src/adapters/BaseAdapter.sol";
import {FeeLedger} from "../../src/adapters/FeeLedger.sol";
import {ISenzuAdapter} from "../../src/interfaces/ISenzuAdapter.sol";
import {ISenzuLockCallback} from "../../src/interfaces/ISenzuLockCallback.sol";
import {ISenzuRangeAdapter} from "../../src/interfaces/ISenzuRangeAdapter.sol";
import {PythStructs} from "../../src/interfaces/external/pyth/PythStructs.sol";
import {RangeAmounts} from "../../src/libraries/RangeAmounts.sol";
import {Shape} from "../../src/libraries/Types.sol";
import {LiquidityAmounts} from "../../src/libraries/uniswap/LiquidityAmounts.sol";

/// @dev What a DEX hook can run in the middle of a liquidity change (MockAdapter.setHook)
interface IMockHook {
    function onModify() external;
}

/// @dev Adapter with no DEX behind it. Tests set shapes, fee growth, pool price and liquidity to add.
contract MockAdapter is FeeLedger, ISenzuRangeAdapter {
    struct Pos {
        address token0;
        address token1;
        uint160 sqrtPaX96;
        uint160 sqrtPbX96;
        uint128 liquidity;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
        uint256 uncollected0;
        uint256 uncollected1;
    }

    mapping(uint256 => Pos) public positions;
    uint160 public poolSqrtPrice;
    uint128 public nextIncrease;
    /// @dev Called like a v4 hook: after liquidity is added (before the collateral mints units for it) and before
    ///      liquidity is removed (after the collateral burned the units)
    address public hook;
    bool public pokeReverts;
    bool public pokeBurnsGas;
    /// @dev Wei short of what's requested a collect pays, like the v3 NFPM, whose rounding can hold a few wei less
    ///      than the holders' summed fees
    uint128 public shortPay;
    /// @dev Growth booked by the last successful poke, per position
    mapping(uint256 => uint256[2]) internal _booked;
    /// @dev The `data` the last increase and decrease got
    bytes public lastIncreaseData;
    bytes public lastDecreaseData;
    /// @dev Tokens already counted by previous deposits/increases, so `used0`/`used1` report what just went in
    mapping(address => uint256) internal _held;

    constructor(address collateral_) FeeLedger(collateral_) {}

    // ==== test helpers ====
    function setPoolSqrtPrice(uint160 sqrtPriceX96) external {
        poolSqrtPrice = sqrtPriceX96;
    }

    function setNextIncrease(uint128 liquidity) external {
        nextIncrease = liquidity;
    }

    function setHook(address hook_) external {
        hook = hook_;
    }

    /// @dev Credits `amount0/1` of fees to the whole position, like swaps through the range would
    function accrueFees(uint256 lpId, uint256 amount0, uint256 amount1) external {
        Pos storage p = positions[lpId];
        p.feeGrowth0X128 += amount0 * (1 << 128) / p.liquidity;
        p.feeGrowth1X128 += amount1 * (1 << 128) / p.liquidity;
        p.uncollected0 += amount0;
        p.uncollected1 += amount1;
    }

    // ==== views ====
    function units(uint256 lpId) public view returns (uint256) {
        return positions[lpId].liquidity;
    }

    function shape(uint256 lpId) public view returns (Shape memory) {
        Pos memory p = positions[lpId];
        return Shape(p.token0, p.token1, p.sqrtPaX96, p.sqrtPbX96, p.liquidity);
    }

    function tokens(uint256 lpId) external view returns (address, address) {
        return (positions[lpId].token0, positions[lpId].token1);
    }

    function amountsAt(uint256 lpId, uint256 accountUnits, uint256 totalUnits, uint160[5] calldata sqrtPricesX96)
        external
        view
        returns (uint256[5] memory, uint256[5] memory)
    {
        return RangeAmounts.ofUnits(shape(lpId), accountUnits, totalUnits, sqrtPricesX96);
    }

    function poolId(uint256) external pure returns (bytes32) {}

    function poolSqrtPriceX96(uint256) external view returns (uint160) {
        return poolSqrtPrice;
    }

    function _previewGrowth(uint256 lpId) internal view override returns (uint256, uint256) {
        return (positions[lpId].feeGrowth0X128, positions[lpId].feeGrowth1X128);
    }

    /// @dev A poke that reverts, like a v4 or Ekubo fee collect with one pool token paused
    function setPokeReverts(bool reverts) external {
        pokeReverts = reverts;
    }

    /// @dev A poke that runs out of gas, whatever it is given
    function setPokeBurnsGas(bool burns) external {
        pokeBurnsGas = burns;
    }

    function setShortPay(uint128 wei_) external {
        shortPay = wei_;
    }

    // ==== collateral only ====
    function _pokeGrowth(uint256 lpId) internal override returns (uint256, uint256) {
        if (pokeReverts) revert("token paused");
        if (pokeBurnsGas) {
            while (true) {}
        }
        Pos storage p = positions[lpId];
        _booked[lpId] = [p.feeGrowth0X128, p.feeGrowth1X128];
        return (p.feeGrowth0X128, p.feeGrowth1X128);
    }

    /// @dev data = abi.encode(token0, token1, sqrtPa, sqrtPb, liquidity)
    function deposit(uint256 lpId, address, address, bytes calldata data)
        external
        onlyCollateral
        returns (uint256 liquidity, address token0, address token1, uint256 used0, uint256 used1)
    {
        uint160 a;
        uint160 b;
        uint128 l;
        (token0, token1, a, b, l) = abi.decode(data, (address, address, uint160, uint160, uint128));
        positions[lpId] = Pos(token0, token1, a, b, l, 0, 0, 0, 0);
        liquidity = l;
        (used0, used1) = (_take(token0), _take(token1));
    }

    function _take(address token) internal returns (uint256 added) {
        if (token.code.length == 0) return 0;
        uint256 bal = MockERC20(token).balanceOf(address(this));
        if (bal > _held[token]) {
            added = bal - _held[token];
            _held[token] = bal;
        }
    }

    function quoteDeposit(bytes calldata data)
        external
        view
        override(ISenzuAdapter, BaseAdapter)
        returns (address token0, address token1, uint256 amount0, uint256 amount1)
    {
        uint160 a;
        uint160 b;
        uint128 l;
        (token0, token1, a, b, l) = abi.decode(data, (address, address, uint160, uint160, uint128));
        (amount0, amount1) = LiquidityAmounts.getAmountsForLiquidity(poolSqrtPrice, a, b, l, true);
    }

    function increaseLiquidity(uint256 lpId, address account, uint256 balance, address, bytes calldata data)
        external
        onlyCollateral
        returns (uint256 added, uint256 used0, uint256 used1)
    {
        lastIncreaseData = data;
        (uint256 growth0, uint256 growth1) = _pokeGrowth(lpId);
        _checkpoint(account, lpId, balance, growth0, growth1);
        added = nextIncrease;
        Pos storage p = positions[lpId];
        p.liquidity += uint128(added);
        if (hook != address(0)) IMockHook(hook).onModify();
        (used0, used1) = (_take(p.token0), _take(p.token1));
    }

    /// @dev Pays out the removed liquidity's tokens at the pool price (minted, like a real pool would send them)
    function decreaseLiquidity(
        uint256 lpId,
        uint256 liquidity,
        address account,
        uint256 balance,
        address to,
        bytes calldata data
    ) external onlyCollateral returns (uint256 amount0, uint256 amount1) {
        lastDecreaseData = data;
        (uint256 growth0, uint256 growth1) = _pokeGrowth(lpId);
        _checkpoint(account, lpId, balance, growth0, growth1);
        Pos storage p = positions[lpId];
        if (hook != address(0)) IMockHook(hook).onModify();
        p.liquidity -= uint128(liquidity);
        if (balance == liquidity) _payFeesOwed(account, lpId, account);
        if (poolSqrtPrice == 0) return (0, 0);
        (amount0, amount1) =
            LiquidityAmounts.getAmountsForLiquidity(poolSqrtPrice, p.sqrtPaX96, p.sqrtPbX96, uint128(liquidity));
        MockERC20(p.token0).mint(to, amount0);
        MockERC20(p.token1).mint(to, amount1);
    }

    function _sendFees(uint256 lpId, address to, uint128 amount0, uint128 amount1)
        internal
        override
        returns (uint256, uint256)
    {
        Pos storage p = positions[lpId];
        uint128 pay0 = amount0 > shortPay ? amount0 - shortPay : 0;
        uint128 pay1 = amount1 > shortPay ? amount1 - shortPay : 0;
        p.uncollected0 -= pay0;
        p.uncollected1 -= pay1;
        MockERC20(p.token0).mint(to, pay0);
        MockERC20(p.token1).mint(to, pay1);
        return (pay0, pay1);
    }
}

/// @dev Runs a list of calls to SenzuCollateral inside lock(). Must be an operator of the account it acts for.
contract MockLockRouter is ISenzuLockCallback {
    address public immutable collateral;

    constructor(address collateral_) {
        collateral = collateral_;
    }

    function run(bytes[] calldata calls) external {
        (bool ok, bytes memory ret) = collateral.call(abi.encodeWithSignature("lock(bytes)", abi.encode(calls)));
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function senzuLockAcquired(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == collateral, "not collateral");
        bytes[] memory calls = abi.decode(data, (bytes[]));
        for (uint256 i; i < calls.length; ++i) {
            (bool ok, bytes memory ret) = collateral.call(calls[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
        return "";
    }
}

import {SenzuBaseRouter} from "../../src/periphery/SenzuBaseRouter.sol";

/// @dev A router whose swaps run at fixed rates per (tokenIn, tokenOut): out = in · num / den, minted to itself; what
///      it sells goes to a sink and is counted in `kept`. A route of abi.encode(uint256) pays exactly that much instead
///      (a test's chosen fill). An exact output sells ceil(out · den / num)
contract MockSwapRouter is SenzuBaseRouter {
    address internal constant SINK = address(0x51C);

    mapping(address => mapping(address => uint256[2])) public rate;
    /// @dev What it sold, by token
    mapping(address => uint256) public kept;

    constructor(address collateral_, address weth_, address pyth_) SenzuBaseRouter(collateral_, weth_, pyth_) {}

    function setRate(address tokenIn, address tokenOut, uint256 num, uint256 den) external {
        rate[tokenIn][tokenOut] = [num, den];
    }

    function _swapExactIn(address tokenIn, address tokenOut, uint256 amountIn, bytes memory route) internal override {
        uint256 amountOut;
        if (route.length == 32) {
            amountOut = abi.decode(route, (uint256));
        } else {
            uint256[2] memory r = rate[tokenIn][tokenOut];
            amountOut = amountIn * r[0] / r[1];
        }
        _sell(tokenIn, amountIn);
        MockERC20(tokenOut).mint(address(this), amountOut);
    }

    function _swapExactOut(address tokenIn, address tokenOut, uint256 amountOut, bytes memory) internal override {
        uint256[2] memory r = rate[tokenIn][tokenOut];
        _sell(tokenIn, (amountOut * r[1] + r[0] - 1) / r[0]);
        MockERC20(tokenOut).mint(address(this), amountOut);
    }

    function _sell(address token, uint256 amount) private {
        kept[token] += amount;
        MockERC20(token).transfer(SINK, amount);
    }
}

/// @dev Permit2's AllowanceTransfer as the router uses it, without signature checks (a fork test runs the real one)
contract MockPermit2 {
    mapping(address user => mapping(address token => mapping(address spender => uint160))) public allowed;
    address public lastOwner;

    function permit(address owner, IAllowanceTransfer.PermitBatch memory batch, bytes calldata) external {
        lastOwner = owner;
        for (uint256 i; i < batch.details.length; ++i) {
            allowed[owner][batch.details[i].token][batch.spender] = batch.details[i].amount;
        }
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        uint160 left = allowed[from][token][msg.sender];
        require(left >= amount, "allowance");
        allowed[from][token][msg.sender] = left - amount;
        MockERC20(token).transferFrom(from, to, amount);
    }
}
