// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {RewardLedger} from "../../src/adapters/RewardLedger.sol";

/// @notice The least a reward token needs: what the harness mints, and transfers out of it
contract HarnessRewardToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/**
 *  @title  RewardLedgerHarness
 *  @notice RewardLedger unchanged, with its five steps open to the vectors: a booking, rewards held, a checkpoint,
 *          a seize (its deployer is the collateral, and calls the real `seize`) and a payout, all with any arguments.
 *          No cut. Never deployed; only run by `script/SdkVectors.s.sol`.
 */
contract RewardLedgerHarness is RewardLedger {
    mapping(address => mapping(uint256 => uint256)) public balances;

    constructor(HarnessRewardToken reward) RewardLedger(msg.sender, address(reward)) {}

    function setBalance(address account, uint256 lpId, uint256 bal) external {
        balances[account][lpId] = bal;
    }

    function book(uint256 lpId, uint256 arrived, uint256 liquidity) external {
        _bookRewardGrowth(lpId, arrived, liquidity);
    }

    function hold(uint256 amount) external {
        HarnessRewardToken(rewardToken).mint(address(this), amount);
        _holdRewards(amount);
    }

    function checkpoint(address account, uint256 lpId, uint256 balance) external {
        _checkpointRewards(account, lpId, balance);
    }

    function pay(address account, uint256 lpId) external returns (uint256) {
        return _payRewards(account, lpId, address(this));
    }

    function _balanceOf(address account, uint256 lpId) internal view override returns (uint256) {
        return balances[account][lpId];
    }

    function _unbookedRewardGrowth(uint256) internal pure override returns (uint256) {}

    function _feeCut() internal pure override returns (uint256, address) {
        return (0, address(0));
    }

    function units(uint256) public pure override returns (uint256) {}

    function _tokens(uint256) internal pure override returns (address, address) {}

    function _pendingFees(uint256) internal pure override returns (uint256, uint256, uint256) {}

    function _collectPending(uint256) internal override {}

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
