// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {V4EmptyMarketHandler, V4Handler} from "./V4Handler.sol";

/// @notice The V4Handler as Medusa targets it (`medusa fuzz --target-contracts V4Medusa`), as V3Medusa: the native
///         ETH/USDC pool
contract V4Medusa is V4Handler(true) {
    function property_coreAndV4AdapterHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}

/// @notice The same on a WETH/USDC pool of two ERC-20s
contract V4MedusaErc20 is V4Handler(false) {
    function property_coreAndV4AdapterHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}

/// @notice Cold-start empty-market Medusa target on v4
contract V4EmptyMarketMedusa is V4EmptyMarketHandler {
    function property_coreAndV4EmptyMarketHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}
