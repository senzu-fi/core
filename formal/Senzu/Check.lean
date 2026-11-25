import Senzu.Proofs.BadDebt
import Senzu.Proofs.Borrowers
import Senzu.Proofs.Fee
import Senzu.Proofs.Fees
import Senzu.Proofs.Liquidation
import Senzu.Proofs.Repayments
import Senzu.Proofs.Rewards
import Senzu.Proofs.Health
import Senzu.Proofs.Range

/-!
# Each frozen statement, proved for Senzu

One theorem per row of the README's table, typed by the statement in `Spec.lean` applied to Senzu's wiring.
-/

namespace Senzu.Check

open Spec Proofs FeeModel

theorem c1 : SharesRounding toShares := sharesRounding
theorem c2 : AssetsRounding toAssets := assetsRounding
theorem l1 : SupplyWithdrawRoundTrip senzu := supplyWithdrawRoundTrip
theorem l2 : RoundTripLoss senzu := roundTripLoss
theorem l3 : PriceNeverFalls senzu := priceNeverFalls
theorem l4 : PriceNeverFallsOverAnySequence senzu := priceNeverFallsOverAnySequence
theorem l5 : NoFreeLunch senzu := noFreeLunch
theorem b1 : BorrowOwesAtLeastBorrowed senzu := borrowOwesAtLeastBorrowed
theorem b2 : RepayNeverOverCredits senzu := repayNeverOverCredits
theorem m1 : CashNeverNegative writeOff := cashNeverNegative
theorem w1 : WriteOffCostsAtMostTheDebt writeOff := writeOffCostsAtMostTheDebt
theorem w2 : BorrowThenWriteOff writeOff := borrowThenWriteOff
theorem w3 : WriteOffChargesNoOneElse writeOff := writeOffChargesNoOneElse
theorem w4 : LastWriteOffLeavesNoDebt writeOff := lastWriteOffLeavesNoDebt
theorem b3 : RepayNeverLowersDebtPrice repay := repayNeverLowersDebtPrice
theorem b4 : RepayPaysLenders repay := repayPaysLenders
theorem b5 : LastRepayLeavesNoDebt repay := lastRepayLeavesNoDebt
theorem r1 : NothingStuck senzuRewards := nothingStuck
theorem r2 : PaidAtMostArrived senzuRewards := paidAtMostArrived
theorem r3 : CreditedAtMostItsShare senzuRewards := creditedAtMostItsShare
theorem fl1 {A : Type} [Fintype A] [DecidableEq A] : FeesCollectable (senzuFees A) := feesCollectable
theorem fl2 {A : Type} [Fintype A] [DecidableEq A] : FeesPaidAtMostEarned (senzuFees A) := feesPaidAtMostEarned
theorem fl3 {A : Type} [Fintype A] [DecidableEq A] : FeesCreditedAtMostItsShare (senzuFees A) :=
  feesCreditedAtMostItsShare
theorem s1 {A : Type} [Fintype A] [DecidableEq A] : SeizeMovesItsShare (senzuFees A) := seizeMovesItsShare
theorem s2 {A : Type} [Fintype A] [DecidableEq A] : SeizeNeverReverts (senzuFees A) := seizeNeverReverts
theorem q1 : LiquidatorTakesNoMore senzuLiquidation := liquidatorTakesNoMore
theorem q2 : LendersLoseOnlyRounding senzuLiquidation := lendersLoseOnlyRounding
theorem q3 : CoveredStaysCovered senzuLiquidation := coveredStaysCovered
theorem q4 : DustNeverBlocks senzuLiquidation := dustNeverBlocks
theorem f1 : FeeAtMostShareOfGain liquidationFee := feeAtMostShareOfGain
theorem f2 : NoFeeOnBadDebt liquidationFee := noFeeOnBadDebt
theorem f3 : FeeLosesOnlyRounding liquidationFee := feeLosesOnlyRounding
theorem h1 : CheckCoversBox fourCorners := checkCoversBox
theorem a1 : NeverOverReports amountsAt := neverOverReports
theorem a2 : RangeValueConcave rangeValue := rangeValueConcave
theorem a3 : NeverReverts amountsAt := neverReverts
theorem a4 : SplittingAddsNothing amountsAt := splittingAddsNothing

/-- Statement 4 for every adapter: a range position that passes the exact check is covered across the box. -/
theorem rangePositionCovered {a b L : ℝ} (ha : 0 < a) (hab : a < b) (hL : 0 ≤ L) :
    ∀ p σ d others pen, 0 < p.1 → 0 < p.2 → 1 ≤ σ.1 → 1 ≤ σ.2 → 0 ≤ d.1 → 0 ≤ d.2 → 0 ≤ pen →
      fourCorners (rangeValue a b L) p σ d others pen →
      ∀ q ∈ box p σ, ∀ others' ≤ others, pen * debtsAt d others' q ≤ rangeValue a b L q :=
  fun p σ d others pen => h1 (rangeValue a b L) p σ d others pen (a2 a b L ha hab hL)

end Senzu.Check
