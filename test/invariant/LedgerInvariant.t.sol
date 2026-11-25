// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {RewardLedger} from "../../src/adapters/RewardLedger.sol";
import {MockERC20} from "../mocks/Mocks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Test} from "forge-std/Test.sol";

/**
 *  @dev `FeeLedger`, `HeldFeesAdapter` and `RewardLedger` with no exchange under them: fees and rewards appear when
 *       the handler says so, and units are whatever the handler (its collateral) says. It follows the adapters' own
 *       rules: fees are collected and rewards settled before any change of a position's units but a seize, which
 *       books nothing and moves the seized units' bookmarks to the liquidator
 */
contract LedgerWorld is RewardLedger {
    MockERC20 public immutable token0;
    MockERC20 public immutable token1;

    /// @dev What the "exchange" owes each position and the ledger hasn't collected or booked
    mapping(uint256 lpId => uint256[2]) public pendingFees;
    mapping(uint256 lpId => uint256) public pendingRewards;

    /// @dev The protocol's cut, sent to this address
    address public constant CUT_TO = address(0xC07);
    uint256 public constant CUT_WAD = 0.02e18;

    constructor(address collateral_, MockERC20 token0_, MockERC20 token1_, MockERC20 reward_)
        RewardLedger(collateral_, address(reward_))
    {
        (token0, token1) = (token0_, token1_);
    }

    function accrueFees(uint256 lpId, uint256 fee0, uint256 fee1) external onlyCollateral {
        pendingFees[lpId][0] += fee0;
        pendingFees[lpId][1] += fee1;
    }

    function accrueRewards(uint256 lpId, uint256 amount) external onlyCollateral {
        pendingRewards[lpId] += amount;
    }

    /// @dev The exchange pays the pending rewards, or only `arrived` of them: the rest is forfeited
    function settleRewards(uint256 lpId, uint256 arrived) public onlyCollateral {
        uint256 earned = pendingRewards[lpId];
        if (arrived > earned) arrived = earned;
        pendingRewards[lpId] = 0;
        MockERC20(rewardToken).mint(address(this), arrived);
        _bookRewardGrowth(lpId, arrived, units(lpId));
        _holdRewards(arrived);
    }

    /// @dev The exchange lowers what it would pay (Aero's gauge after an emergency unstake): that part never arrives
    function lowerRewards(uint256 lpId, uint256 amount) external onlyCollateral {
        pendingRewards[lpId] -= amount;
    }

    function poke(uint256 lpId) external onlyCollateral {
        _collectPending(lpId);
    }

    /// @dev What every adapter does before `account`'s units change: collect, settle, checkpoint
    function beforeChange(uint256 lpId, address account, uint256 balance) external onlyCollateral {
        settleRewards(lpId, type(uint256).max);
        _collectPending(lpId);
        _checkpointHeld(account, lpId, balance);
    }

    function claimRewards(address account, uint256 lpId) external onlyCollateral returns (uint256) {
        settleRewards(lpId, type(uint256).max);
        _checkpointRewards(account, lpId, _balanceOf(account, lpId));
        return _payRewards(account, lpId, account);
    }

    function feesOwedBeforeCut(address account, uint256 lpId) external view returns (uint256, uint256) {
        return _feesOwedBeforeCut(account, lpId);
    }

    function rewardsOwedBeforeCut(address account, uint256 lpId) external view returns (uint256) {
        return _rewardsOwedBeforeCut(account, lpId);
    }

    /// @dev What `account` is owed of the rewards booked so far, the exchange's pending ones left out
    function rewardsBooked(address account, uint256 lpId) external view returns (uint256) {
        (uint256 growth, uint256 owed) = this.rewardCheckpoints(account, lpId);
        return owed + FullMath.mulDiv(_balanceOf(account, lpId), rewardGrowthX128[lpId] - growth, Q128);
    }

    function _feeCut() internal pure override returns (uint256, address) {
        return (CUT_WAD, CUT_TO);
    }

    function units(uint256 lpId) public view override returns (uint256) {
        return LedgerHandler(collateral).totalSupply(lpId);
    }

    function _tokens(uint256) internal view override returns (address, address) {
        return (address(token0), address(token1));
    }

    function _pendingFees(uint256 lpId) internal view override returns (uint256, uint256, uint256) {
        uint256[2] memory p = pendingFees[lpId];
        return (p[0], p[1], p[0] == 0 && p[1] == 0 ? 0 : units(lpId));
    }

    function _collectPending(uint256 lpId) internal override {
        uint256[2] memory p = pendingFees[lpId];
        if (p[0] == 0 && p[1] == 0) return;
        delete pendingFees[lpId];
        token0.mint(address(this), p[0]);
        token1.mint(address(this), p[1]);
        // forge-lint: disable-next-line(unsafe-typecast)
        _bookFees(lpId, address(token0), address(token1), p[0], p[1], uint128(units(lpId)));
    }

    function _unbookedRewardGrowth(uint256 lpId) internal view override returns (uint256) {
        uint256 pending = pendingRewards[lpId];
        return pending == 0 ? 0 : FullMath.mulDiv(pending, Q128, units(lpId));
    }

    function tokens(uint256) external pure override returns (address, address) {}

    function amountsAt(uint256, uint256, uint256, uint160[5] calldata)
        external
        pure
        override
        returns (uint256[5] memory, uint256[5] memory)
    {}

    function poolSqrtPriceX96(uint256) external pure override returns (uint160) {}

    function poolId(uint256) external pure override returns (bytes32) {}

    function deposit(uint256, address, address, bytes calldata)
        external
        pure
        override
        returns (uint256, address, address, uint256, uint256)
    {
        revert();
    }

    function increaseLiquidity(uint256, address, uint256, address, bytes calldata)
        external
        pure
        override
        returns (uint256, uint256, uint256)
    {
        revert();
    }

    function decreaseLiquidity(uint256, uint256, address, uint256, address, bytes calldata)
        external
        pure
        override
        returns (uint256, uint256)
    {
        revert();
    }
}

/// @dev Drives the ledgers as their collateral, and keeps a shadow of what each account should be owed
contract LedgerHandler is Test {
    uint256 internal constant ACCOUNTS = 3;
    uint256 internal constant IDS = 2;
    uint256 internal constant Q64 = 1 << 64;

    LedgerWorld public world;
    MockERC20 internal token0 = new MockERC20("T0", 18);
    MockERC20 internal token1 = new MockERC20("T1", 6);
    MockERC20 internal reward = new MockERC20("RWD", 18);

    mapping(address => mapping(uint256 => uint256)) public balanceOf;
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Fair share per account, position and kind (fee0, fee1, rewards), times 2^64. Fees are shared when the
    ///      exchange earns them, rewards when it pays them: until then it can still cancel them
    mapping(address => mapping(uint256 => uint256[3])) internal fairQ;
    /// @dev The part of `fairQ` earned since the account's own last checkpoint: a seize moves the seized units' part
    ///      of it to the liquidator
    mapping(address => mapping(uint256 => uint256[3])) internal openQ;
    /// @dev Per position and kind: what the exchange gave (rewards: paid), what it forfeited, and what was paid out
    mapping(uint256 => uint256[3]) public given;
    mapping(uint256 => uint256) public forfeited;
    mapping(uint256 => uint256[3]) public paid;

    /// @dev Partial seizes from `(account, id)`: each floors `moved` down, so up to 1 wei of remainder stays with `from`
    mapping(address => mapping(uint256 => uint256)) internal seizesFrom;
    /// @dev Checkpoints so far: each floors once, so each can leave a wei unowed
    uint256 public steps;
    uint256 public violations;
    string public lastViolation;
    mapping(bytes32 => uint256) public calls;

    constructor() {
        world = new LedgerWorld(address(this), token0, token1, reward);
    }

    function isOperator(address, address) external pure returns (bool) {
        return true;
    }

    function account(uint256 seed) public pure returns (address) {
        return address(uint160(0xA000 + seed % ACCOUNTS));
    }

    function _id(uint256 seed) internal pure returns (uint256) {
        return 1 + seed % IDS;
    }

    function _fail(string memory why) internal {
        ++violations;
        lastViolation = why;
    }

    /// @dev Before the protocol's cut: what the ledger books, and what fairness is measured on (rewards: booked)
    function _owed(address who, uint256 id) internal view returns (uint256[3] memory o) {
        (o[0], o[1]) = world.feesOwedBeforeCut(who, id);
        o[2] = world.rewardsBooked(who, id);
    }

    function _cut(uint256 amount) internal view returns (uint256) {
        return amount * world.CUT_WAD() / 1e18;
    }

    /// @dev Nobody's owed falls unless it was paid (`payee`)
    modifier watched(address payee) {
        uint256[3][] memory before = _allOwed();
        _;
        _checkNoFall(before, payee, address(0));
    }

    /// @dev A seize: the borrower's owed falls by what the seized units take, and the liquidator's merged bookmark
    ///      rounds against it by up to a wei
    modifier watchedSeize(address from, address to) {
        uint256[3][] memory before = _allOwed();
        _;
        _checkNoFall(before, from, to);
    }

    function _allOwed() internal view returns (uint256[3][] memory before) {
        before = new uint256[3][](ACCOUNTS * IDS);
        for (uint256 a; a < ACCOUNTS; ++a) {
            for (uint256 i; i < IDS; ++i) {
                before[a * IDS + i] = _owed(account(a), i + 1);
            }
        }
    }

    function _checkNoFall(uint256[3][] memory before, address payee, address roundedDown) internal {
        for (uint256 a; a < ACCOUNTS; ++a) {
            for (uint256 i; i < IDS; ++i) {
                uint256[3] memory nowOwed = _owed(account(a), i + 1);
                for (uint256 k; k < 3; ++k) {
                    uint256 was = before[a * IDS + i][k];
                    if (nowOwed[k] >= was || account(a) == payee) continue;
                    if (account(a) == roundedDown && was - nowOwed[k] <= 1) continue;
                    _fail("an account's owed fell without being paid");
                }
            }
        }
        _checkFair();
    }

    function _credit(uint256 id, uint256 k, uint256 amount) internal {
        given[id][k] += amount;
        uint256 supply = totalSupply[id];
        for (uint256 a; a < ACCOUNTS; ++a) {
            uint256 q = FullMath.mulDiv(amount * balanceOf[account(a)][id], Q64, supply);
            fairQ[account(a)][id][k] += q;
            openQ[account(a)][id][k] += q;
        }
    }

    /// @dev `who` checkpointed its own units: what they earned so far stays its own
    function _close(address who, uint256 id, bool fees, bool rewards) internal {
        if (fees) (openQ[who][id][0], openQ[who][id][1]) = (0, 0);
        if (rewards) openQ[who][id][2] = 0;
    }

    function _debit(address who, uint256 id, uint256 k, uint256 amount) internal {
        uint256 q = amount * Q64;
        fairQ[who][id][k] = fairQ[who][id][k] > q ? fairQ[who][id][k] - q : 0;
    }

    /// @dev The ledger floors at every checkpoint: owed is never above the fair share, and under it by at most a
    ///      wei per checkpoint. The rewards view adds the exchange's pending ones and never shows less than booked
    function _checkFair() internal {
        for (uint256 a; a < ACCOUNTS; ++a) {
            for (uint256 i = 1; i <= IDS; ++i) {
                uint256[3] memory owed = _owed(account(a), i);
                if (world.rewardsOwedBeforeCut(account(a), i) < owed[2]) {
                    _fail("the rewards view shows less than booked");
                }
                for (uint256 k; k < 3; ++k) {
                    uint256 fair = fairQ[account(a)][i][k] / Q64;
                    if (owed[k] > fair + seizesFrom[account(a)][i] + 1) _fail("owed more than the pro-rata share");
                    if (owed[k] + steps + 1 < fair) _fail("owed less than the pro-rata share");
                }
            }
        }
    }

    /*  ================================================
                             Actions
        ================================================  */

    /// @dev The exchange pays everything pending, shared by the units held now (what each change does first)
    function _settleAll(uint256 id) internal {
        uint256 pending = world.pendingRewards(id);
        world.settleRewards(id, pending);
        if (pending > 0) _credit(id, 2, pending);
    }

    function mint(uint256 who, uint256 idSeed, uint256 amount) public watched(address(0)) {
        (address to, uint256 id) = (account(who), _id(idSeed));
        amount = bound(amount, 1e3, 1e24);
        _settleAll(id);
        world.beforeChange(id, to, balanceOf[to][id]);
        _close(to, id, true, true);
        balanceOf[to][id] += amount;
        totalSupply[id] += amount;
        ++steps;
        ++calls[keccak256("mint")];
    }

    function burn(uint256 who, uint256 idSeed, uint256 amount) public watched(address(0)) {
        (address from, uint256 id) = (account(who), _id(idSeed));
        uint256 balance = balanceOf[from][id];
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        // Keep what's left splittable: dust liquidity makes growth per unit huge, as no real position has
        if (totalSupply[id] - amount != 0 && totalSupply[id] - amount < 1e3) amount = balance;
        if (totalSupply[id] - amount != 0 && totalSupply[id] - amount < 1e3) return;
        _settleAll(id);
        world.beforeChange(id, from, balance);
        _close(from, id, true, true);
        balanceOf[from][id] -= amount;
        totalSupply[id] -= amount;
        ++steps;
        ++calls[keccak256("burn")];
    }

    /// @dev A liquidation: the seized units take their pro-rata share of everything unclaimed (credited and open)
    function seize(uint256 fromSeed, uint256 toSeed, uint256 idSeed, uint256 amount)
        public
        watchedSeize(account(fromSeed), account(toSeed))
    {
        (address from, address to, uint256 id) = (account(fromSeed), account(toSeed), _id(idSeed));
        uint256 balance = balanceOf[from][id];
        if (balance == 0 || from == to) return;
        amount = bound(amount, 1, balance);
        for (uint256 k; k < 3; ++k) {
            uint256 moved = FullMath.mulDiv(fairQ[from][id][k], amount, balance);
            fairQ[from][id][k] -= moved;
            fairQ[to][id][k] += moved;
        }
        world.seize(id, from, to, balanceOf[to][id], amount);
        balanceOf[from][id] -= amount;
        balanceOf[to][id] += amount;
        if (amount < balance) ++seizesFrom[from][id];
        steps += 2;
        ++calls[keccak256("seize")];
    }

    function accrueFees(uint256 idSeed, uint256 fee0, uint256 fee1) public watched(address(0)) {
        uint256 id = _id(idSeed);
        if (totalSupply[id] == 0) return;
        (fee0, fee1) = (bound(fee0, 0, 1e27), bound(fee1, 0, 1e15));
        world.accrueFees(id, fee0, fee1);
        _credit(id, 0, fee0);
        _credit(id, 1, fee1);
        ++calls[keccak256("accrueFees")];
    }

    function accrueRewards(uint256 idSeed, uint256 amount) public watched(address(0)) {
        uint256 id = _id(idSeed);
        if (totalSupply[id] == 0) return;
        amount = bound(amount, 0, 1e27);
        world.accrueRewards(id, amount);
        ++calls[keccak256("accrueRewards")];
    }

    function poke(uint256 idSeed) public watched(address(0)) {
        world.poke(_id(idSeed));
        ++calls[keccak256("poke")];
    }

    /// @dev The exchange pays the pending rewards; one time in four it keeps a part (an emergency unstake)
    function settleRewards(uint256 idSeed, uint256 seed) public watched(address(0)) {
        uint256 id = _id(idSeed);
        uint256 earned = world.pendingRewards(id);
        uint256 arrived = seed % 4 == 0 ? earned * (seed % 101) / 100 : earned;
        world.settleRewards(id, arrived);
        if (arrived > 0) _credit(id, 2, arrived);
        if (earned > arrived) {
            forfeited[id] += earned - arrived;
            ++calls[keccak256("forfeit")];
        }
        ++calls[keccak256("settleRewards")];
    }

    /// @dev The exchange lowers what it would pay (Aero's gauge after an emergency unstake, once its pool settles):
    ///      only the view falls, nobody was credited it
    function previewFalls(uint256 idSeed, uint256 seed) public watched(address(0)) {
        uint256 id = _id(idSeed);
        uint256 amount = world.pendingRewards(id) * (1 + seed % 100) / 100;
        if (amount == 0) return;
        world.lowerRewards(id, amount);
        forfeited[id] += amount;
        ++calls[keccak256("previewFalls")];
    }

    function collectFees(uint256 who, uint256 idSeed) public watched(account(who)) {
        (address holder, uint256 id) = (account(who), _id(idSeed));
        (uint256 owed0, uint256 owed1) = world.feesOwed(holder, id);
        (uint256 gross0, uint256 gross1) = world.feesOwedBeforeCut(holder, id);
        address cutTo = world.CUT_TO();
        (uint256 was0, uint256 was1) = (token0.balanceOf(holder), token1.balanceOf(holder));
        (uint256 cutWas0, uint256 cutWas1) = (token0.balanceOf(cutTo), token1.balanceOf(cutTo));
        vm.prank(holder);
        (uint256 fee0, uint256 fee1) = world.collectFees(holder, id, holder);
        if (balanceOf[holder][id] > 0) _close(holder, id, true, true);
        if (fee0 != owed0 || fee1 != owed1) _fail("a collect paid something else than the fees owed");
        if (token0.balanceOf(holder) - was0 != fee0 || token1.balanceOf(holder) - was1 != fee1) {
            _fail("a collect returned something else than it sent");
        }
        (uint256 cut0, uint256 cut1) = (token0.balanceOf(cutTo) - cutWas0, token1.balanceOf(cutTo) - cutWas1);
        if (cut0 != _cut(gross0) || cut1 != _cut(gross1)) _fail("a collect's cut is not the rate of what was owed");
        if (fee0 + cut0 != gross0 || fee1 + cut1 != gross1) _fail("a collect's pay and cut are not what was owed");
        (uint256 left0, uint256 left1) = world.feesOwed(holder, id);
        if (left0 != 0 || left1 != 0) _fail("fees still owed after a collect");
        _debit(holder, id, 0, gross0);
        _debit(holder, id, 1, gross1);
        paid[id][0] += gross0;
        paid[id][1] += gross1;
        ++steps;
        ++calls[keccak256("collectFees")];
    }

    function claimRewards(uint256 who, uint256 idSeed) public watched(account(who)) {
        (address holder, uint256 id) = (account(who), _id(idSeed));
        // The claim books the pending rewards first: they arrive for the position and are held
        _settleAll(id);
        uint256 owed = world.rewardsBooked(holder, id);
        uint256 positionHas = world.positionRewards(id);
        uint256 available = positionHas < world.rewardsHeld() ? positionHas : world.rewardsHeld();
        uint256 was = reward.balanceOf(holder);
        uint256 cutWas = reward.balanceOf(world.CUT_TO());
        uint256 amount = world.claimRewards(holder, id);
        _close(holder, id, false, true);
        uint256 cut = reward.balanceOf(world.CUT_TO()) - cutWas;
        if (reward.balanceOf(holder) - was != amount) _fail("a claim returned something else than it sent");
        uint256 taken = amount + cut;
        if (taken != (owed < available ? owed : available)) {
            _fail("a claim paid something else than owed, or what arrived for the position");
        }
        if (cut != _cut(taken)) _fail("a claim's cut is not the rate of what it paid");
        if (world.rewardsBooked(holder, id) != owed - taken) _fail("a claim took more off the owed than it paid");
        _debit(holder, id, 2, taken);
        paid[id][2] += taken;
        ++steps;
        ++calls[keccak256("claimRewards")];
    }

    /*  ================================================
                            Invariants
        ================================================  */

    function checkAll() external view {
        require(violations == 0, lastViolation);
        uint256 held0;
        uint256 held1;
        uint256 rewardsOwedAll;
        uint256 positionRewardsAll;
        for (uint256 id = 1; id <= IDS; ++id) {
            uint256[3] memory owed;
            for (uint256 a; a < ACCOUNTS; ++a) {
                uint256[3] memory o = _owed(account(a), id);
                (owed[0], owed[1], owed[2]) = (owed[0] + o[0], owed[1] + o[1], owed[2] + o[2]);
            }
            (,, uint128 h0, uint128 h1) = world.fees(id);
            held0 += h0;
            held1 += h1;
            // Fees: owed never above what the position was given and hasn't paid, and the unowed rest is rounding
            for (uint256 k; k < 2; ++k) {
                uint256 has = given[id][k] - paid[id][k];
                require(owed[k] <= has, "fees owed exceed what the position has");
                require(has - owed[k] <= steps + 1, "fees nobody is owed pile up");
                require((k == 0 ? h0 : h1) + world.pendingFees(id, k) == has, "held + pending != given - paid");
            }
            // Rewards: a position's holders are owed and paid at most what arrived for it, and the unowed rest is
            // rounding
            uint256 arrived = given[id][2];
            require(paid[id][2] <= arrived, "a position's holders were paid more than arrived for it");
            require(
                world.positionRewards(id) == arrived - paid[id][2],
                "a position's rewards are not what arrived for it and wasn't paid"
            );
            positionRewardsAll += world.positionRewards(id);
            require(owed[2] <= arrived - paid[id][2], "rewards owed exceed what arrived");
            require(arrived - paid[id][2] - owed[2] <= steps + 1, "rewards nobody is owed pile up");
            rewardsOwedAll += owed[2];
        }
        require(world.held(address(token0)) == held0 && token0.balanceOf(address(world)) == held0, "token0 held");
        require(world.held(address(token1)) == held1 && token1.balanceOf(address(world)) == held1, "token1 held");
        require(
            world.held(address(reward)) == world.rewardsHeld()
                && reward.balanceOf(address(world)) == world.rewardsHeld(),
            "rewards held"
        );
        require(positionRewardsAll == world.rewardsHeld(), "rewards held are not the positions'");
        require(rewardsOwedAll <= world.rewardsHeld(), "rewards owed exceed the ledger's");
    }
}

/// @notice The fee and reward ledgers alone, after any sequence of actions
contract LedgerInvariantTest is Test {
    LedgerHandler handler;

    function setUp() public {
        handler = new LedgerHandler();
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = LedgerHandler.mint.selector;
        selectors[1] = LedgerHandler.burn.selector;
        selectors[2] = LedgerHandler.seize.selector;
        selectors[3] = LedgerHandler.accrueFees.selector;
        selectors[4] = LedgerHandler.accrueRewards.selector;
        selectors[5] = LedgerHandler.poke.selector;
        selectors[6] = LedgerHandler.settleRewards.selector;
        selectors[7] = LedgerHandler.collectFees.selector;
        selectors[8] = LedgerHandler.claimRewards.selector;
        selectors[9] = LedgerHandler.previewFalls.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 200
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ledgersHold() public view {
        handler.checkAll();
    }

    /// @notice A long pseudo-random run must reach every action, or a green invariant means little
    function test_handlerReachesEveryAction() public {
        uint256 seed = 0xC0FFEE;
        for (uint256 i; i < 3000; ++i) {
            seed = uint256(keccak256(abi.encode(seed)));
            (uint256 a, uint256 b, uint256 c) = (seed >> 8, seed >> 40, seed >> 72);
            uint256 pick = seed % 10;
            if (pick == 0) handler.mint(a, b, c);
            else if (pick == 1) handler.burn(a, b, c);
            else if (pick == 2) handler.seize(a, b, c, seed >> 100);
            else if (pick == 3) handler.accrueFees(a, b, c);
            else if (pick == 4) handler.accrueRewards(a, b);
            else if (pick == 5) handler.poke(a);
            else if (pick == 6) handler.settleRewards(a, b);
            else if (pick == 7) handler.collectFees(a, b);
            else if (pick == 8) handler.previewFalls(a, b);
            else handler.claimRewards(a, b);
        }
        handler.checkAll();
        string[12] memory names = [
            "mint",
            "burn",
            "seize",
            "accrueFees",
            "accrueRewards",
            "poke",
            "settleRewards",
            "forfeit",
            "collectFees",
            "claimRewards",
            "seize",
            "previewFalls"
        ];
        for (uint256 i; i < names.length; ++i) {
            assertGt(handler.calls(keccak256(bytes(names[i]))), 0, names[i]);
        }
    }
}

/// @notice The reward ledger's edge cases, one by one: what the invariant run found or once let through
contract RewardLedgerCasesTest is Test {
    LedgerHandler h;
    LedgerWorld world;
    address alice;
    address bob;
    address carol;

    function setUp() public {
        h = new LedgerHandler();
        world = h.world();
        (alice, bob, carol) = (h.account(0), h.account(1), h.account(2));
    }

    function _wallet(address who) internal view returns (uint256) {
        return MockERC20(world.rewardToken()).balanceOf(who);
    }

    /// @notice Alice is liquidated while 100 is pending in position 1: it goes with her units to bob. The exchange
    ///         then forfeits all of it, so nobody was owed it, and carol's 100 in position 2 is hers in full. Alice
    ///         once kept a credit for it and was paid carol's rewards, or the next holder's (test_forfeitAfterSeize...)
    function test_seizeThenForfeit_isNeverPaidFromAnotherPosition() public {
        h.mint(0, 0, 1e18);
        h.mint(2, 1, 1e18);
        h.accrueRewards(0, 100e18);
        h.accrueRewards(1, 100e18);
        assertEq(world.rewardsOwedBeforeCut(alice, 1), 100e18, "alice sees it pending");
        h.seize(0, 1, 0, 1e18);
        assertEq(world.rewardsOwedBeforeCut(alice, 1), 0, "it went with her units");
        assertEq(world.rewardsOwedBeforeCut(bob, 1), 100e18, "to bob");
        h.settleRewards(0, 0);
        h.settleRewards(1, 1);
        assertEq(h.forfeited(1), 100e18, "all of it forfeited");
        assertEq(world.rewardsHeld(), 100e18, "carol's arrived");
        assertEq(world.rewardsOwedBeforeCut(alice, 1) + world.rewardsOwedBeforeCut(bob, 1), 0, "nobody owed it");

        h.claimRewards(0, 0);
        h.claimRewards(1, 0);
        assertEq(_wallet(alice) + _wallet(bob), 0, "nothing arrived for position 1");
        h.claimRewards(2, 1);
        assertApproxEqAbs(_wallet(carol), 98e18, 1, "carol's 100, less the 2% cut");
        assertEq(world.positionRewards(1), 0);
        h.checkAll();
    }

    /// @notice What alice claimed stays hers; what she hadn't, booked or not, is split by units at a seize
    function test_seize_splitsByUnitsWhatWasntClaimed() public {
        h.mint(0, 0, 1e18);
        h.accrueRewards(0, 100e18);
        h.claimRewards(0, 0);
        assertApproxEqAbs(_wallet(alice), 98e18, 1, "her 100, less the 2% cut");
        h.accrueRewards(0, 40e18);
        h.settleRewards(0, 1);
        h.accrueRewards(0, 60e18);
        h.seize(0, 1, 0, 5e17);
        h.settleRewards(0, 1);
        assertApproxEqAbs(world.rewardsBooked(alice, 1), 50e18, 1, "half the 40 booked and half the 60 pending");
        assertApproxEqAbs(world.rewardsBooked(bob, 1), 50e18, 1, "the other halves, on the seized units");
        assertApproxEqAbs(_wallet(alice), 98e18, 1, "what she claimed is untouched");
        h.checkAll();
    }

    /// @notice Fees the same way, into a liquidator that already holds units: bob's own and the seized units each
    ///         keep what they earned
    function test_seize_splitsUncollectedFeesByUnits() public {
        h.mint(0, 0, 1e18);
        h.mint(1, 0, 1e18);
        h.accrueFees(0, 100e18, 0);
        h.collectFees(1, 0);
        h.accrueFees(0, 20e18, 0);
        // alice is open 60 (50 + 10), bob 10; half her units take 30 of hers to bob
        h.seize(0, 1, 0, 5e17);
        (uint256 alice0,) = world.feesOwedBeforeCut(alice, 1);
        (uint256 bob0,) = world.feesOwedBeforeCut(bob, 1);
        assertApproxEqAbs(alice0, 30e18, 2, "alice keeps the half on the units she kept");
        assertApproxEqAbs(bob0, 40e18, 2, "bob: his 10, and 30 with the seized units");
        h.accrueFees(0, 30e18, 0);
        (alice0,) = world.feesOwedBeforeCut(alice, 1);
        (bob0,) = world.feesOwedBeforeCut(bob, 1);
        assertApproxEqAbs(alice0, 30e18 + 7.5e18, 2, "then a quarter of the 30: she holds 0.5 of 2");
        assertApproxEqAbs(bob0, 40e18 + 22.5e18, 2, "and three quarters to bob");
        h.collectFees(0, 0);
        h.collectFees(1, 0);
        h.checkAll();
    }

    /// @notice Fees and rewards already credited into `checkpoint.owed` by an earlier partial redeem/increase move pro
    ///         rata on a seize: a 50% seize moves half of credited owed, and a 100% seize moves all of it
    function test_seize_splitsCreditedOwedByUnits() public {
        h.mint(0, 0, 1e18);
        h.accrueFees(0, 100e18, 200e6);
        h.accrueRewards(0, 100e18);
        // A tiny partial burn checkpoints and credits fees & rewards into `checkpoint.owed` without paying them
        h.burn(0, 0, 1e15);
        uint256 rem = h.balanceOf(alice, 1);
        (,, uint128 aliceOwed0, uint128 aliceOwed1) = world.checkpoints(alice, 1);
        (, uint256 aliceROwed) = world.rewardCheckpoints(alice, 1);
        assertApproxEqAbs(aliceOwed0, 100e18, 2, "fees0 credited");
        assertApproxEqAbs(aliceOwed1, 200e6, 2, "fees1 credited");
        assertApproxEqAbs(aliceROwed, 100e18, 2, "rewards credited");

        // 50% partial seize moves half of credited fees and half of credited rewards to bob
        uint256 half = rem / 2;
        h.seize(0, 1, 0, half);
        (uint256 a0, uint256 a1) = world.feesOwedBeforeCut(alice, 1);
        (uint256 b0, uint256 b1) = world.feesOwedBeforeCut(bob, 1);
        assertApproxEqAbs(b0, uint256(aliceOwed0) / 2, 2, "50% seize moves half credited fee0");
        assertApproxEqAbs(b1, uint256(aliceOwed1) / 2, 2, "50% seize moves half credited fee1");
        assertEq(a0 + b0, aliceOwed0, "no fee0 created or lost");
        assertEq(a1 + b1, aliceOwed1, "no fee1 created or lost");
        uint256 aR = world.rewardsBooked(alice, 1);
        uint256 bR = world.rewardsBooked(bob, 1);
        assertApproxEqAbs(bR, aliceROwed / 2, 2, "50% seize moves half credited rewards");
        assertEq(aR + bR, aliceROwed, "no rewards created or lost");

        // 100% seize of Alice's remaining units moves all remaining credited owed to carol
        h.seize(0, 2, 0, h.balanceOf(alice, 1));
        (uint256 a0After, uint256 a1After) = world.feesOwedBeforeCut(alice, 1);
        assertEq(a0After + a1After, 0, "borrower keeps no credited fees after 100% seize");
        assertEq(world.rewardsBooked(alice, 1), 0, "borrower keeps no credited rewards after 100% seize");
        (uint256 c0, uint256 c1) = world.feesOwedBeforeCut(carol, 1);
        assertEq(c0, a0, "carol got all remaining fee0");
        assertEq(c1, a1, "carol got all remaining fee1");
        assertEq(world.rewardsBooked(carol, 1), aR, "carol got all remaining rewards");
        h.checkAll();
    }

    /// @notice The exchange pays only part of what it showed, split between holders of odd sizes: together they are
    ///         owed at most what arrived, and every one of them is paid in full
    function test_partialPayout_holdersAreOwedNoMoreThanArrived() public {
        h.mint(0, 0, 1e18 + 1);
        h.mint(1, 0, 3e18 + 7);
        h.mint(2, 0, 7e18 + 3);
        h.accrueRewards(0, 1e18 + 13);
        // One time in four the exchange keeps a part: 336 keeps 33% of it
        h.settleRewards(0, 336);
        uint256 arrived = (1e18 + 13) - h.forfeited(1);
        uint256 owed = world.rewardsOwedBeforeCut(alice, 1) + world.rewardsOwedBeforeCut(bob, 1)
            + world.rewardsOwedBeforeCut(carol, 1);
        assertLe(owed, arrived, "never owed more than arrived");

        h.claimRewards(0, 0);
        h.claimRewards(1, 0);
        h.claimRewards(2, 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(world.rewardsOwedBeforeCut(h.account(i), 1), 0, "everyone paid in full");
        }
        h.checkAll();
    }

    /// @notice The exchange lowers what it shows after a seize: only the view falls, and the position can still be
    ///         redeemed, claimed and liquidated (a checkpoint at the higher preview once underflowed)
    function test_previewFallingAfterASeize_blocksNothing() public {
        h.mint(0, 0, 2e18);
        h.accrueRewards(0, 100e18);
        h.seize(0, 1, 0, 1e18);
        h.previewFalls(0, 49);
        assertEq(h.forfeited(1), 50e18);

        world.rewardsOwed(alice, 1);
        h.seize(0, 2, 0, 5e17);
        h.burn(1, 0, 1e18);
        h.claimRewards(0, 0);
        h.claimRewards(2, 0);
        h.burn(0, 0, 5e17);
        assertLe(_wallet(alice) + _wallet(bob) + _wallet(carol), 50e18, "paid at most what arrived");
        h.checkAll();
    }
}
