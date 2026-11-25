import Mathlib.Analysis.Convex.Function
import Mathlib.Analysis.SpecialFunctions.Sqrt
import Senzu.Market

/-!
# Range positions and the health check

Every adapter's `amountsAt` ends in `RangeAmounts.at(lower, upper, L, √prices)`; they differ only in the whole
position's liquidity `totalLiq` they start from (v3, v4, Aero: the position's; Ekubo: net of its withdrawal fee; v2:
from √k and the pair's supply, between the lowest and highest Uniswap prices). So this model covers all five.

The integer part matches the Solidity (vectors `amount_delta`, `liquidity_amounts`). The exact part, in ℝ, is
Uniswap's curve without rounding and the four-corner check. Prices there are USD per wei of
each token, so decimals drop out (the check's `scale` does the same).
-/

namespace Senzu

def Q96 : Nat := 2 ^ 96
def U160 : Nat := 2 ^ 160

/-! ## Integer: as the Solidity computes it -/

/-- `SqrtPriceMath.getAmount0Delta`: L·2^96·(hi − lo) / hi / lo, rounded as asked, reverting when `lo = 0`. -/
def amount0Delta (a b L : Nat) (r : Rounding) : Option Nat := do
  let lo := min a b
  let hi := max a b
  require (lo ≠ 0)
  match r with
  | .down => pure ((← mulDiv (L * Q96) (hi - lo) hi) / lo)
  | .up => pure (((← mulDivUp (L * Q96) (hi - lo) hi) + lo - 1) / lo)

/-- `SqrtPriceMath.getAmount1Delta`: L·(hi − lo) / 2^96, rounded as asked. -/
def amount1Delta (a b L : Nat) (r : Rounding) : Option Nat :=
  match r with
  | .down => mulDiv L (max a b - min a b) Q96
  | .up => mulDivUp L (max a b - min a b) Q96

/-- `LiquidityAmounts.getAmountsForLiquidity(s, a, b, L)`, rounded down: all token0 at or below the range, both
inside it, all token1 at or above it. -/
def amountsForLiquidity (s a b L : Nat) : Option (Nat × Nat) :=
  if s ≤ min a b then (amount0Delta (min a b) (max a b) L .down).map (·, 0)
  else if s < max a b then do pure (← amount0Delta s (max a b) L .down, ← amount1Delta (min a b) s L .down)
  else (amount1Delta (min a b) (max a b) L .down).map (0, ·)

/-- `RangeAmounts.at` at one √price: no liquidity holds nothing. -/
def rangeAt (a b L s : Nat) : Option (Nat × Nat) :=
  if L = 0 then some (0, 0) else amountsForLiquidity s a b L

/-- The liquidity `units` of `totalUnits` own of a position holding `totalLiq`: ⌊units · totalLiq / totalUnits⌋ as
a `uint128` (`RangeAmounts.liquidityOf`; the same step in v2's and Ekubo's `amountsAt`). -/
def liquidityOf (units totalLiq totalUnits : Nat) : Option Nat :=
  if totalUnits = 0 then some 0 else do toU128 (← mulDiv units totalLiq totalUnits)

/-- An adapter's `amountsAt` at one √price, from the whole position's liquidity. -/
def amountsAt (a b totalLiq units totalUnits s : Nat) : Option (Nat × Nat) := do
  rangeAt a b (← liquidityOf units totalLiq totalUnits) s

/-! ## The health check's √price and a corner's collateral -/

def MIN_SQRT_PRICE : Nat := 4295128739
def MAX_SQRT_PRICE : Nat := 1461446703485210103287273052203988822378723970342

/-- Checked `uint256` multiplication. -/
def mul256 (a b : Nat) : Option Nat := if a * b < U256 then some (a * b) else none

/-- Clamped to Uniswap's √prices. -/
def clampSqrt (r : Nat) : Nat := max MIN_SQRT_PRICE (min r MAX_SQRT_PRICE)

/-- √(n / d) · 2^96, rounded down: all 96 fractional bits below a ratio of 2^64, 64 above (2^192 · n / d would
overflow), the top √price from 2^128 or a zero `d` (`FixedPointMathLib.sqrt` is `Nat.sqrt`). -/
def sqrtOfRatio (n d : Nat) : Option Nat :=
  if d = 0 ∨ 2 ^ 128 ≤ n / d then some MAX_SQRT_PRICE
  else if n / d < 2 ^ 64 then (mulDiv n (2 ^ 192) d).map (fun x => clampSqrt (Nat.sqrt x))
  else (mulDiv n (2 ^ 128) d).map (fun x => clampSqrt (Nat.sqrt x * 2 ^ 32))

/-- `HealthMath._sqrtPriceX96Scaled`: √(p0·scale1 / (p1·scale0)) · 2^96, rounded down, clamped to Uniswap's range. -/
def sqrtPriceX96Scaled (p0 p1 scale0 scale1 : Nat) : Option Nat := do
  sqrtOfRatio (← mul256 p0 scale1) (← mul256 p1 scale0)

/-- What the check values a slice at, at one corner (`HealthMath._applyCorner`): the adapter's amounts at the
check's √price, each at its price per whole token over its `scale` (10^decimals), rounded down. -/
def checkCollateral (a b totalLiq units totalUnits q0 q1 scale0 scale1 : Nat) : Option Nat := do
  let s ← sqrtPriceX96Scaled q0 q1 scale0 scale1
  let (x, y) ← amountsAt a b totalLiq units totalUnits s
  add256 (← mulDiv x q0 scale0) (← mulDiv y q1 scale1)

/-! ## Exact, in ℝ -/

/-- What liquidity `L` between √prices `a < b` holds at √price `s`, with no rounding. -/
noncomputable def holdings (a b L s : ℝ) : ℝ × ℝ :=
  if s ≤ a then (L * (1 / a - 1 / b), 0)
  else if s < b then (L * (1 / s - 1 / b), L * (s - a))
  else (0, L * (b - a))

/-- What liquidity `L` between √prices `a < b` is worth at prices `p = (pX, pY)`: the holdings after arbitrage
(at √price √(pX / pY)), each token at its price. -/
noncomputable def rangeValue (a b L : ℝ) (p : ℝ × ℝ) : ℝ :=
  let h := holdings a b L (Real.sqrt (p.1 / p.2))
  h.1 * p.1 + h.2 * p.2

/-- The oracle's prices `p`, each divided or multiplied by its σ. -/
noncomputable def corners (p σ : ℝ × ℝ) : List (ℝ × ℝ) :=
  [(p.1 / σ.1, p.2 / σ.2), (p.1 * σ.1, p.2 / σ.2), (p.1 / σ.1, p.2 * σ.2), (p.1 * σ.1, p.2 * σ.2)]

/-- Debts of `d.1` token0 and `d.2` token1 at prices `q`, plus other debts worth `others` (their own σ applied). -/
def debtsAt (d : ℝ × ℝ) (others : ℝ) (q : ℝ × ℝ) : ℝ :=
  d.1 * q.1 + d.2 * q.2 + others

/-- The four-corner check: at each corner, the position's value is at least the penalty × its debts there. -/
def fourCorners (V : ℝ × ℝ → ℝ) (p σ d : ℝ × ℝ) (others pen : ℝ) : Prop :=
  ∀ c ∈ corners p σ, pen * debtsAt d others c ≤ V c

end Senzu
