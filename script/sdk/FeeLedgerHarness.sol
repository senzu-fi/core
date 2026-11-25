// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {HeldFeesAdapter} from "../../src/adapters/HeldFeesAdapter.sol";
import {HarnessRewardToken} from "./RewardLedgerHarness.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/**
 *  @title  FeeLedgerHarness
 *  @notice HeldFeesAdapter unchanged, for one position, with a pretend DEX: `accrue` is what the DEX earns for the
 *          position, `_collectPending` pays all of it in token0 and books it (`_bookFees`). `mint` and `burn` are an
 *          adapter's increase and decrease (collect, `_checkpointHeld`, change the units); a collect is the real
 *          `collectFees`; a seize is the real `seize` then the core's unit move (its own collateral, so both run in one
 *          call). No cut. Never deployed; only run by `script/SdkVectors.s.sol`.
 */
contract FeeLedgerHarness is HeldFeesAdapter {
    using SafeCastLib for uint256;

    uint256 public constant LP = 1;
    address internal immutable token0;

    mapping(address => uint256) public balances;
    uint256 public totalUnits;
    uint256 public pending0;

    constructor(HarnessRewardToken token) HeldFeesAdapter(address(this)) {
        token0 = address(token);
    }

    function accrue(uint256 amount) external {
        require(totalUnits > 0);
        pending0 += amount;
    }

    function mint(address account, uint256 n) external {
        _collectPending(LP);
        _checkpointHeld(account, LP, balances[account]);
        balances[account] += n;
        totalUnits += n;
    }

    function burn(address account, uint256 n) external {
        _collectPending(LP);
        _checkpointHeld(account, LP, balances[account]);
        balances[account] -= n;
        totalUnits -= n;
    }

    /// @dev `seize` as the collateral calls it, then the collateral's unit move (OpenZeppelin's ERC6909 `_update`)
    function seizeAndMove(address from, address to, uint256 n) external {
        this.seize(LP, from, to, balances[to], n);
        uint256 fromBalance = balances[from];
        require(fromBalance >= n);
        balances[from] = fromBalance - n;
        balances[to] += n;
    }

    function _balanceOf(address account, uint256) internal view override returns (uint256) {
        return balances[account];
    }

    function _tokens(uint256) internal view override returns (address, address) {
        return (token0, address(0));
    }

    function _pendingFees(uint256) internal view override returns (uint256, uint256, uint256) {
        if (totalUnits == 0) return (0, 0, 0);
        return (pending0, 0, totalUnits);
    }

    function _collectPending(uint256 lpId) internal override {
        uint256 fee = pending0;
        if (fee == 0) return;
        pending0 = 0;
        HarnessRewardToken(token0).mint(address(this), fee);
        _bookFees(lpId, token0, address(0), fee, 0, totalUnits.toUint128());
    }

    function _feeCut() internal pure override returns (uint256, address) {
        return (0, address(0));
    }

    function units(uint256) public pure override returns (uint256) {}

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
