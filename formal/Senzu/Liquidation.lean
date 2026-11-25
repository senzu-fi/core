import Senzu.Market

/-!
# Liquidation

`LiquidationLogic.seizeFor`, after the health check: `_bearable` (the penalty a position can bear) and what follows
it (the units a repayment takes). Values are USD with 18 decimals (wad); `price` is USD per whole debt token and
`unit` is `10 ^ decimals`. The health check's own numbers (collateral and debt in USD) are arguments, so a property
proved here holds whatever the oracle and the adapter say. The vectors (`seize`, and `seize_fee` with the protocol
fee) compare it with the Solidity.
-/

namespace Senzu

def WAD : Nat := 10 ^ 18
def MIN_INCENTIVE : Nat := 102 * 10 ^ 16
def MAX_PENALTY : Nat := 125 * 10 ^ 16

/-- `LiquidationLogic._bearable`: the penalty, down to collateral / debt, never under `MIN_INCENTIVE`. -/
def bearable (collateralUsd debtUsd penalty : Nat) : Option Nat :=
  if debtUsd = 0 then some penalty else do
    let ratio ← mulDiv collateralUsd WAD debtUsd
    pure (if ratio ≥ penalty then penalty else if ratio < MIN_INCENTIVE then MIN_INCENTIVE else ratio)

/-- The rest of `LiquidationLogic.seizeFor`: `(units seized, assets repaid)`. A repayment worth, with the penalty, at
least the collateral takes every unit, and its repayment is capped at what the collateral covers at `MIN_INCENTIVE`,
rounded up. -/
def seize (units collateralUsd repay price unit penalty : Nat) : Option (Nat × Nat) := do
  let repayUsd ← mulDiv repay price unit
  let withPenalty ← mulDiv repayUsd penalty WAD
  if collateralUsd ≤ withPenalty then do
    let atMin ← mulDivUp collateralUsd WAD MIN_INCENTIVE
    let coverable ← mulDivUp atMin unit price
    pure (units, if coverable < repay then coverable else repay)
  else do
    let seized ← mulDiv units withPenalty collateralUsd
    pure (seized, repay)

/-- A liquidation's two steps, so `Spec` can state properties of any implementation and `Mutants` can show the
statements reject wrong ones. -/
structure Liquidation where
  bearable : Nat → Nat → Nat → Option Nat
  seize : Nat → Nat → Nat → Nat → Nat → Nat → Option (Nat × Nat)

/-- Senzu's. -/
def senzuLiquidation : Liquidation := ⟨bearable, seize⟩

/-- `LiquidationLogic.liquidate` once the position is liquidatable: a debt of `debt` assets (worth `debtUsd` with
the position's other debts) against `units` worth `collateralUsd`, and a liquidator offering `maxRepay`. -/
def Liquidation.liquidate (l : Liquidation) (collateralUsd debtUsd debt price unit penalty maxRepay units : Nat) :
    Option (Nat × Nat) := do
  require (collateralUsd ≠ 0)
  require (debt ≠ 0)
  let repay := min maxRepay debt
  require (repay ≠ 0)
  let b ← l.bearable collateralUsd debtUsd penalty
  l.seize units collateralUsd repay price unit b

/-- The protocol fee, from a seize's result: collateral `C` and debts `D` in USD, the repaid debt's whole amount `d`,
its `price` and `unit`, the position's units `U`, the `seized` units and `repaid` assets, the DEX's `feeWad`, and
whether the position owes another market. Given as an argument so `Spec` can state properties of any rule. -/
abbrev FeeRule := Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → Bool → Option Nat

/-- The fee in `LiquidationLogic.seizeFor`: nothing when collateral is under 1.02 × the debts or the liquidation
writes debt off (takes every unit and leaves debt), else `feeWad` of what the seized units are worth in the repaid
asset less what was repaid, rounded down. -/
def liquidationFee : FeeRule := fun C D d price unit U seized repaid feeWad other =>
  if feeWad = 0 ∨ seized = 0 then some 0 else do
    let atFloor ← mulDiv C WAD MIN_INCENTIVE
    if atFloor < D ∨ (seized = U ∧ (repaid < d ∨ other = true)) then some 0 else do
      let seizedUsd ← mulDiv C seized U
      let seizedAssets ← mulDiv seizedUsd unit price
      if repaid < seizedAssets then mulDiv (seizedAssets - repaid) feeWad WAD else some 0

/-- `LiquidationLogic.liquidate` with its fee: `(units seized, assets repaid, fee)`. The fee is computed from the
seize's result and never feeds back into it; the vectors (`seize_fee`) check the Solidity does the same. -/
def Liquidation.liquidateWithFee (l : Liquidation) (fee : FeeRule)
    (collateralUsd debtUsd debt price unit penalty maxRepay units feeWad : Nat) (other : Bool) :
    Option (Nat × Nat × Nat) := do
  let (seized, repaid) ← l.liquidate collateralUsd debtUsd debt price unit penalty maxRepay units
  let f ← fee collateralUsd debtUsd debt price unit units seized repaid feeWad other
  pure (seized, repaid, f)

end Senzu
