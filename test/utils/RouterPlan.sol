// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {ISenzuRouter} from "../../src/interfaces/ISenzuRouter.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";

/// @dev Builds router action lists: `RouterPlan.Plan memory p; p = p.borrow(...).swap(...).increase(...);`
library RouterPlan {
    struct Plan {
        bytes actions;
        bytes[] params;
    }

    uint256 internal constant ALL = type(uint256).max;

    function pull(Plan memory p, address token, uint256 amount) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Pull, abi.encode(token, amount));
    }

    function open(Plan memory p, bytes memory data, address token0, address token1)
        internal
        pure
        returns (Plan memory)
    {
        return open(p, data, token0, token1, 0, 0);
    }

    function open(Plan memory p, bytes memory data, address token0, address token1, uint256 min0, uint256 min1)
        internal
        pure
        returns (Plan memory)
    {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (token0, token1);
        uint256[] memory minimums = new uint256[](2);
        (minimums[0], minimums[1]) = (min0, min1);
        return _add(p, ISenzuRouter.Action.Open, abi.encode(data, tokens, minimums));
    }

    function openExact(
        Plan memory p,
        bytes memory data,
        uint256 fromUser0,
        uint256 fromUser1,
        uint256 maxBorrow0,
        uint256 maxBorrow1
    ) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.OpenExact, abi.encode(data, fromUser0, fromUser1, maxBorrow0, maxBorrow1));
    }

    function increase(Plan memory p, uint256 id, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)
        internal
        pure
        returns (Plan memory)
    {
        return increase(p, id, amount0, amount1, min0, min1, "");
    }

    function increase(
        Plan memory p,
        uint256 id,
        uint256 amount0,
        uint256 amount1,
        uint256 min0,
        uint256 min1,
        bytes memory adapterData
    ) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Increase, abi.encode(id, amount0, amount1, min0, min1, adapterData));
    }

    function increaseFromUser(
        Plan memory p,
        uint256 id,
        uint256 fromUser0,
        uint256 fromUser1,
        uint256 min0,
        uint256 min1
    ) internal pure returns (Plan memory) {
        return _add(
            p, ISenzuRouter.Action.IncreaseFromUser, abi.encode(id, fromUser0, fromUser1, min0, min1, bytes(""))
        );
    }

    function borrow(Plan memory p, uint256 id, address asset, uint256 amount) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Borrow, abi.encode(id, asset, amount));
    }

    function swap(
        Plan memory p,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minOut,
        bytes memory route
    ) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Swap, abi.encode(tokenIn, tokenOut, amountIn, minOut, route));
    }

    function swapForDebt(Plan memory p, uint256 id, address asset, address tokenIn, uint256 maxIn, bytes memory route)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.SwapForDebt, abi.encode(id, asset, tokenIn, maxIn, route));
    }

    function repay(Plan memory p, uint256 id, address asset, uint256 amount) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Repay, abi.encode(id, asset, amount));
    }

    function redeem(Plan memory p, uint256 id, uint256 units, uint256 min0, uint256 min1)
        internal
        pure
        returns (Plan memory)
    {
        return redeem(p, id, units, min0, min1, "");
    }

    function redeem(Plan memory p, uint256 id, uint256 units, uint256 min0, uint256 min1, bytes memory adapterData)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.Redeem, abi.encode(id, units, min0, min1, adapterData));
    }

    function collectFees(Plan memory p, uint256 id) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.CollectFees, abi.encode(id));
    }

    function compound(Plan memory p, uint256 id, uint256 min0, uint256 min1) internal pure returns (Plan memory) {
        return compound(p, id, min0, min1, "");
    }

    function compound(Plan memory p, uint256 id, uint256 min0, uint256 min1, bytes memory adapterData)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.Compound, abi.encode(id, min0, min1, adapterData));
    }

    function supply(Plan memory p, address asset, uint256 amount) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Supply, abi.encode(asset, amount));
    }

    function withdraw(Plan memory p, address asset, uint256 shares) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.Withdraw, abi.encode(asset, shares));
    }

    function authorize(Plan memory p, bool lending, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.Authorize, abi.encode(lending, deadline, v, r, s));
    }

    function postPrices(Plan memory p, bytes[] memory updates) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.PostPrices, abi.encode(updates));
    }

    function liquidate(Plan memory p, address borrower, uint256 id, address asset, uint256 repayAssets)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.Liquidate, abi.encode(borrower, id, asset, repayAssets));
    }

    function permit(Plan memory p, IAllowanceTransfer.PermitBatch memory batch, bytes memory signature)
        internal
        pure
        returns (Plan memory)
    {
        return _add(p, ISenzuRouter.Action.Permit, abi.encode(batch, signature));
    }

    function claimRewards(Plan memory p, uint256 id) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.ClaimRewards, abi.encode(id));
    }

    function setStake(Plan memory p, uint256 id, bool on) internal pure returns (Plan memory) {
        return _add(p, ISenzuRouter.Action.SetStake, abi.encode(id, on));
    }

    function dex(Plan memory p, uint8 action, bytes memory param) internal pure returns (Plan memory) {
        return _add(p, action, param);
    }

    function _add(Plan memory p, ISenzuRouter.Action action, bytes memory param) private pure returns (Plan memory) {
        return _add(p, uint8(action), param);
    }

    function _add(Plan memory p, uint8 action, bytes memory param) private pure returns (Plan memory) {
        bytes[] memory params = new bytes[](p.params.length + 1);
        for (uint256 i; i < p.params.length; ++i) {
            params[i] = p.params[i];
        }
        params[p.params.length] = param;
        return Plan(bytes.concat(p.actions, bytes1(action)), params);
    }
}
