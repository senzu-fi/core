/-!
# EVM arithmetic

Values are `Nat`; `none` is a revert. Each function matches the Solidity it names, overflow checks included,
so the vectors can compare reverts too.
-/

namespace Senzu

def U256 : Nat := 2 ^ 256
def U128 : Nat := 2 ^ 128

/-- Solidity's `require`. -/
def require (c : Prop) [Decidable c] : Option Unit := if c then some () else none

/-- Checked `uint256` addition. -/
def add256 (a b : Nat) : Option Nat := if a + b < U256 then some (a + b) else none

/-- Checked `uint128` addition. -/
def add128 (a b : Nat) : Option Nat := if a + b < U128 then some (a + b) else none

/-- Checked subtraction. -/
def sub (a b : Nat) : Option Nat := if b ≤ a then some (a - b) else none

/-- `SafeCastLib.toUint128`. -/
def toU128 (a : Nat) : Option Nat := if a < U128 then some a else none

/-- Solady's `fullMulDiv` (the same as Uniswap's `FullMath.mulDiv`): ⌊a·b / c⌋, reverting on a zero denominator or a result of 2^256 or more. -/
def mulDiv (a b c : Nat) : Option Nat :=
  if c = 0 then none else if a * b / c < U256 then some (a * b / c) else none

/-- Solady's `fullMulDivUp` (the same as `FullMath.mulDivRoundingUp`): ⌈a·b / c⌉, with the same reverts. -/
def mulDivUp (a b c : Nat) : Option Nat :=
  if c = 0 then none else if (a * b + c - 1) / c < U256 then some ((a * b + c - 1) / c) else none

end Senzu
