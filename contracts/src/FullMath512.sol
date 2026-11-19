// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISettlementEngine} from "./ISettlementEngine.sol";

/// @title FullMath512
/// @notice 512-bit intermediate `mulDivFloor` / `mulDivCeil`, `gtMul512`, `gcd` & checked 256-bit conversions.
library FullMath512 {
    function _rev(bytes4 sel) internal pure {
        assembly ("memory-safe") {
            mstore(0x00, sel)
            revert(0x00, 0x04)
        }
    }

    function checkedAddU256(uint256 a, uint256 b) internal pure returns (uint256 c) {
        unchecked {
            c = a + b;
            if (c < a) _rev(ISettlementEngine.MathOverflow.selector);
        }
    }

    function checkedSubU256(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a < b) _rev(ISettlementEngine.MathOverflow.selector);
        unchecked {
            return a - b;
        }
    }

    function toInt256(uint256 x) internal pure returns (int256) {
        if (x > uint256(type(int256).max)) _rev(ISettlementEngine.MathOverflow.selector);
        return int256(x);
    }

    function checkedAddI256(int256 a, int256 b) internal pure returns (int256 c) {
        unchecked {
            c = a + b;
            if ((b >= 0 && c < a) || (b < 0 && c > a)) _rev(ISettlementEngine.MathOverflow.selector);
        }
    }

    function checkedSubI256(int256 a, int256 b) internal pure returns (int256 c) {
        unchecked {
            c = a - b;
            if ((b >= 0 && c > a) || (b < 0 && c < a)) _rev(ISettlementEngine.MathOverflow.selector);
        }
    }

    function gtMul512(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (bool res) {
        assembly ("memory-safe") {
            let mmL := mulmod(a, b, not(0))
            let l0 := mul(a, b)
            let l1 := sub(sub(mmL, l0), lt(mmL, l0))
            let mmR := mulmod(c, d, not(0))
            let r0 := mul(c, d)
            let r1 := sub(sub(mmR, r0), lt(mmR, r0))
            res := or(gt(l1, r1), and(eq(l1, r1), gt(l0, r0)))
        }
    }

    function mulDivFloor(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256 result) {
        if (denominator == 0) _rev(ISettlementEngine.DivisionByZero.selector);
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / denominator;
            if (denominator <= prod1) _rev(ISettlementEngine.MathOverflow.selector);

            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = denominator & (~denominator + 1);
            assembly ("memory-safe") {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            inverse *= 2 - denominator * inverse;
            return prod0 * inverse;
        }
    }

    function mulDivCeil(uint256 x, uint256 y, uint256 denominator) internal pure returns (uint256) {
        uint256 floorVal = mulDivFloor(x, y, denominator);
        if (mulmod(x, y, denominator) > 0) {
            if (floorVal == type(uint256).max) _rev(ISettlementEngine.MathOverflow.selector);
            unchecked {
                return floorVal + 1;
            }
        }
        return floorVal;
    }
}
