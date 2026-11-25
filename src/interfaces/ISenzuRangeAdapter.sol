// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Shape} from "../libraries/Types.sol";
import {ISenzuAdapter} from "./ISenzuAdapter.sol";

/**
 *  @title  ISenzuRangeAdapter
 *  @author Senzu
 *  @notice An adapter whose positions are liquidity L between two prices on x·y = k (Uniswap v2, v3, v4, Aero
 *          Slipstream, Ekubo): its `amountsAt` is that range's amounts (`RangeAmounts`). For views, never read by
 *          the core. An account's units of a position hold units · shape.liquidity / totalUnits of it: for
 *          concentrated liquidity units are the liquidity; for Uniswap v2 units are the LP tokens and
 *          shape.liquidity grows with fees while units stay fixed
 */
interface ISenzuRangeAdapter is ISenzuAdapter {
    /// @notice Tokens, range and total liquidity L of a position (L as in the concentrated-liquidity formula)
    function shape(uint256 lpId) external view returns (Shape memory);
}
