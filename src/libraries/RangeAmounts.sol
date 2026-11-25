// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Holdings, Shape} from "./Types.sol";
import {LiquidityAmounts} from "./uniswap/LiquidityAmounts.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

/// @notice What a range position (liquidity L between two prices) holds at given prices: the `amountsAt` of every
///         range adapter, and the previews of positions not opened yet. Rounded down
library RangeAmounts {
    using SafeCastLib for uint256;

    /// @notice What `units` of a position's `totalUnits` hold at each of `sqrtPricesX96`
    function ofUnits(Shape memory shape, uint256 units, uint256 totalUnits, uint160[5] memory sqrtPricesX96)
        internal
        pure
        returns (uint256[5] memory amounts0, uint256[5] memory amounts1)
    {
        Holdings memory holdings =
            at(shape.sqrtPaX96, shape.sqrtPbX96, liquidityOf(shape, units, totalUnits), sqrtPricesX96);
        return (holdings.amounts0, holdings.amounts1);
    }

    /// @notice The liquidity `units` of a position's `totalUnits` own: `units · shape.liquidity / totalUnits`
    function liquidityOf(Shape memory shape, uint256 units, uint256 totalUnits) internal pure returns (uint128) {
        return totalUnits == 0 ? 0 : FullMath.mulDiv(units, shape.liquidity, totalUnits).toUint128();
    }

    /// @notice What `liquidity` between `sqrtPaX96` and `sqrtPbX96` holds at each of `sqrtPricesX96`
    function at(uint160 sqrtPaX96, uint160 sqrtPbX96, uint128 liquidity, uint160[5] memory sqrtPricesX96)
        internal
        pure
        returns (Holdings memory holdings)
    {
        if (liquidity == 0) return holdings;
        for (uint256 i; i < 5; ++i) {
            (holdings.amounts0[i], holdings.amounts1[i]) =
                LiquidityAmounts.getAmountsForLiquidity(sqrtPricesX96[i], sqrtPaX96, sqrtPbX96, liquidity);
        }
    }
}
