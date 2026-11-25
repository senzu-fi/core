// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {V3EmptyMarketHandler, V3Handler} from "./V3Handler.sol";

/// @notice The V3Handler as Medusa targets it: medusa.json fuzzes only the actions, each of which republishes the
///         feeds first, so the property never meets a stale price. The property is the same `checkAll` as Foundry's
contract V3Medusa is V3Handler(true) {
    function property_coreAndV3AdapterHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}

/// @notice The same with USDC as the pool's token0
contract V3MedusaUsdcToken0 is V3Handler(false) {
    function property_coreAndV3AdapterHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}

/// @notice Cold-start empty-market Medusa target on v3
contract V3EmptyMarketMedusa is V3EmptyMarketHandler {
    function property_coreAndV3EmptyMarketHold() public view returns (bool) {
        try this.checkAll() {
            return true;
        } catch {
            return false;
        }
    }
}
