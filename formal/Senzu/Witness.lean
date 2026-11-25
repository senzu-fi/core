import Mathlib.Tactic.NormNum
import Senzu.Spec

/-!
# Witnesses

For each statement, a case where Senzu's wiring meets its hypotheses with nonzero amounts, so no statement
holds only because its hypotheses can't.
-/

namespace Senzu.Witness

/-- C1, C2: both roundings of both conversions succeed, and differ. -/
theorem conversions :
    toShares 1000 10000000 1000000 .down = some 199 ∧ toShares 1000 10000000 1000000 .up = some 200 ∧
    toAssets 1000 10000000 1000000 .down = some 5000 ∧ toAssets 1000 10000000 1000000 .up = some 5001 := by
  decide

/-- L1, L2: supplying 1000 mints 199 shares, which withdraw 995. -/
theorem roundTrip :
    senzu.supplyShares 1000 10000000 1000000 = some 199 ∧
    senzu.withdrawAssets 199 (10000000 + 1000) (1000000 + 199) = some 995 := by
  decide

/-- L3, L4, L5: a supply, an accrual and a withdrawal in sequence. -/
theorem sequence :
    senzu.run ⟨10000000, 1000000⟩ [.supply 1000, .accrue 500, .withdraw 100] =
      some (⟨10001000, 1000099⟩, -500) := by
  decide

/-- B1: borrowing 1000 mints 200 borrow shares, which owe 1001. -/
theorem borrow :
    senzu.borrowShares 1000 10000000 1000000 = some 200 ∧
    senzu.debtOf 200 (10000000 + 1000) (1000000 + 200) = some 1001 := by
  decide

/-- B2: repaying 1000 burns 199 borrow shares. -/
theorem repay : senzu.repayShares 1000 10000000 1000000 = some 199 := by
  decide

/-- W1, W3: writing off 1000 borrow shares, debt 2500.0005, removes 2501, below `totalBorrowAssets`. -/
theorem writeOffOne :
    writeOff ⟨10000000, 5000000, 1000000⟩ 1000 = some (2501, ⟨9997499, 4997499, 999000⟩) := by
  decide

/-- W2: borrowing 1 and being written off costs lenders 2, within the bound of about 2.000002. -/
theorem borrowThenWriteOff :
    addDebt ⟨1000, 1, 1⟩ 1 0 0 = some (500001, 0, ⟨1000, 2, 500002⟩) ∧
    writeOff ⟨1000, 2, 500002⟩ 500001 = some (2, ⟨998, 0, 1⟩) := by
  decide

/-- W4: writing off the last million shares of a 100-wei debt takes all 100. -/
theorem writeOffLast : writeOff ⟨1000, 100, 1000000⟩ 1000000 = some (51, ⟨900, 0, 0⟩) := by
  decide

/-- M1: every kind of action in one sequence. -/
theorem marketSequence :
    marketRun writeOff ⟨0, 0, 0⟩
      [.supply 1000000, .borrow 400000 400 0, .repay 100000000 100000, .writeOff 300000000, .accrue 50,
        .withdraw 1000] =
      some ⟨999150, 400050, 400000000000⟩ := by
  decide

/-- B3, B4: a one-share debt worth a millionth of a wei repays 1, books nothing and gives lenders the wei. -/
theorem repayBook :
    repayAmounts ⟨1000000, 1, 1000000⟩ 1 1 = some (1, 1) ∧
    Senzu.repay ⟨1000000, 1, 1000000⟩ 1 1 = some ⟨1000001, 1, 999999⟩ := by
  decide

/-- B5: two wei of debt on a million shares, all repaid: the market's debt and shares are both 0. -/
theorem repayLast :
    repayAmounts ⟨1000, 2, 1000000⟩ 1000000 2 = some (2, 1000000) ∧
    Senzu.repay ⟨1000, 2, 1000000⟩ 1000000 2 = some ⟨1000, 0, 0⟩ := by
  decide

/-- R1, R2: a holder checkpoints, its position books 1 and receives it, and the holder is paid it. -/
theorem rewardRun :
    ∃ L paid, senzuRewards.run Ledger.empty
      [.checkpoint 1 1 1, .book 1 1 1, .hold 1, .checkpoint 1 1 1, .pay 1 1] = some (L, paid) ∧
      paid 1 = 1 := ⟨_, _, rfl, rfl⟩

/-- R1: a holder of 1 unit checkpoints at a growth of one reward per unit, then takes the 1 unit its co-holder
hadn't checkpointed: the merged bookmark sits halfway, and its 2 units are credited both rewards. -/
theorem rewardSeize :
    ∃ L paid, senzuRewards.run Ledger.empty
      [.book 1 2 2, .checkpoint 2 1 1, .seize 1 2 1 1 1 1, .checkpoint 2 1 2] = some (L, paid) ∧
      (L.checkpoints 2 1).owed = 2 := ⟨_, _, rfl, rfl⟩

/-- Credited `owed` moves pro rata on a seize: a 50% seize moves half of account 1's credited 10 rewards to account 2. -/
theorem rewardSeizeCredited :
    ∃ L paid, senzuRewards.run Ledger.empty
      [.book 1 10 2, .checkpoint 1 1 2, .seize 1 2 1 2 0 1] = some (L, paid) ∧
      (L.checkpoints 1 1).owed = 5 ∧ (L.checkpoints 2 1).owed = 5 := ⟨_, _, rfl, rfl, rfl⟩

/-- R3: a checkpoint, a booking of 1 over 3 units, and a checkpoint, all succeed. -/
theorem rewardShare :
    (do
      let L₁ ← checkpoint Ledger.empty 1 1 1
      let L₂ ← book L₁ 1 1 3
      checkpoint L₂ 1 1 1).isSome = true := by
  decide

section Fees

open FeeModel

/-- FL1, FL2: holders of 1 and 2 units, the position earns 3, and both collect: 1 and 2, all 3 paid. -/
theorem feeRun :
    ∃ s paid, (senzuFees (Fin 2)).run (FeeState.empty _)
      [.mint 0 1, .mint 1 2, .accrue 3, .collect 0, .collect 1] = some (s, paid) ∧ paid = 3 ∧ s.held = 0 :=
  ⟨_, _, rfl, rfl, rfl⟩

/-- FL3: the position above before anyone collects, the DEX owing it 3. -/
def feeOwed : FeeState (Fin 2) :=
  (((senzuFees (Fin 2)).run (FeeState.empty _) [.mint 0 1, .mint 1 2, .accrue 3]).getD (FeeState.empty _, 0)).1

/-- FL3: a checkpoint, a poke of the 3 owed and a checkpoint all succeed, and credit the 2-unit holder 2. -/
theorem feeShare :
    (do
      let s₁ ← FeeModel.checkpoint feeOwed 1
      let s₂ ← poke s₁
      let s₃ ← FeeModel.checkpoint s₂ 1
      pure (s₃.owed 1)) = some 2 := by
  decide

/-- S1, S2: account 0 holds 2 units and has been credited all 10 fees; a seize of 1 unit to account 1, which has
none, succeeds and moves half of them. -/
theorem feeSeize :
    ∃ s paid, (senzuFees (Fin 2)).run (FeeState.empty _)
      [.mint 0 2, .accrue 10, .mint 0 0, .seize 0 1 1] = some (s, paid) ∧ s.owed 0 = 5 ∧ s.owed 1 = 5 :=
  ⟨_, _, rfl, rfl, rfl⟩

end Fees

/-- Q1: collateral 1.1 × a $10 debt bears a penalty of 1.1, and repaying $8 takes 880 of its 1100 units. -/
theorem liquidation :
    bearable 10999998900000000000 (9999999 * 10 ^ 12) MAX_PENALTY = some (11 * 10 ^ 17) ∧
    senzuLiquidation.liquidate 10999998900000000000 (9999999 * 10 ^ 12) 9999999 (10 ^ 18) (10 ^ 6) MAX_PENALTY
      8000000 1100 = some (880, 8000000) := by
  decide

/-- Q2, Q3: that liquidation in a market where it is the only borrower, covered, its debt left over the dust. -/
theorem liquidated :
    Spec.Liquidated senzuLiquidation ⟨10 ^ 7, 9999999, 9999999000000⟩ 9999999000000 10999998900000000000
      (9999999 * 10 ^ 12) 0 (10 ^ 18) (10 ^ 6) MAX_PENALTY 8000000 1100 (11 * 10 ^ 17) 2199999780000000000
      (1999999 * 10 ^ 12) (9999999 * 10 ^ 9) ∧
    MIN_INCENTIVE * (9999999 * 10 ^ 12) ≤ 10999998900000000000 * WAD ∧
    Spec.liquidationRounding ⟨10 ^ 7, 9999999, 9999999000000⟩ (9999999 * 10 ^ 9) (11 * 10 ^ 17) (10 ^ 18)
      (10 ^ 6) ≤ ((MIN_INCENTIVE - WAD : Nat) : ℚ) / WAD * (1999999 * 10 ^ 12 : Nat) := by
  refine ⟨⟨9999999, 9999999 * 10 ^ 12, 880, 8000000, (8000000, 8000000000000), ⟨10 ^ 7, 1999999, 1999999000000⟩,
    1999999, 1999999 * 10 ^ 12, by decide, by decide, by decide, by decide, by decide, rfl, by decide, by decide,
    by decide, by decide, by decide, by decide, rfl, by norm_num⟩, by decide, ?_⟩
  norm_num [Spec.liquidationRounding, Spec.debtPrice, Spec.sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS,
    MIN_INCENTIVE, WAD]

/-- Q4: Q1's liquidation, its $10 debt a market's only borrow, supply above it. -/
theorem dustLiquidation :
    0 < 9999999000000 ∧ 9999999000000 ≤ 9999999000000 ∧ 9999999000000 < U128 ∧
    9999999 + VIRTUAL_ASSETS ≤ 9999999000000 + VIRTUAL_SHARES ∧ 9999999 ≤ 10 ^ 7 ∧ 10 ^ 7 + 9999999 < U128 ∧
    toAssets 9999999000000 9999999 9999999000000 .up = some 9999999 ∧
    mulDivUp 9999999 (10 ^ 18) (10 ^ 6) = some (9999999 * 10 ^ 12) ∧
    0 < 10999998900000000000 ∧ 0 < 10 ^ 18 ∧ 0 < 10 ^ 6 ∧ MIN_INCENTIVE ≤ MAX_PENALTY ∧ MAX_PENALTY ≤ MAX_PENALTY ∧
    10999998900000000000 < 2 ^ 120 ∧ 9999999 * 10 ^ 12 + 0 < 2 ^ 120 ∧ 1100 < U128 ∧ 10 ^ 6 < 2 ^ 120 := by
  decide

/-- F1, F3: Q1's liquidation with a 10% fee. Its 880 units are worth 8.799999 of the token for 8 repaid, so the fee
is 10% of 0.799999, rounded down. -/
theorem liquidationFeePaid :
    senzuLiquidation.liquidateWithFee liquidationFee 10999998900000000000 (9999999 * 10 ^ 12) 9999999 (10 ^ 18)
      (10 ^ 6) MAX_PENALTY 8000000 1100 (10 ^ 17) false = some (880, 8000000, 79999) ∧
    MIN_INCENTIVE * (9999999 * 10 ^ 12) ≤ 10999998900000000000 * WAD := by
  decide

/-- F2: a position under 1.02 × its debts, and a liquidation taking every unit for less than the debt. -/
theorem noFee :
    liquidationFee 100 100 50 1 1 100 60 50 (10 ^ 17) false = some 0 ∧ 100 * WAD < MIN_INCENTIVE * 100 ∧
    liquidationFee 100 0 50 1 1 100 100 40 (10 ^ 17) false = some 0 := by
  decide

/-- H1: a position holding both tokens (value linear, so concave) and owing ¼ of each passes every corner. -/
theorem fourCornersPass :
    Spec.ValueConcave (fun q => q.1 + q.2) ∧
      fourCorners (fun q => q.1 + q.2) (1, 1) (2, 2) (1 / 4, 1 / 4) 0 1 := by
  refine ⟨⟨(convex_Ioi 0).prod (convex_Ioi 0), fun _ _ _ _ _ _ _ _ _ => by simp; linarith⟩, ?_⟩
  simp only [fourCorners, corners, List.mem_cons, List.mem_nil_iff, or_false, forall_eq_or_imp, forall_eq,
    debtsAt]
  norm_num

/-- A2: range [1, 4], liquidity 1, at prices (4, 1): √price 2, holding ¼ token0 and 1 token1, worth 2. -/
theorem rangeValueInside : rangeValue 1 4 1 (4, 1) = 2 := by
  have r4 : Real.sqrt 4 = 2 := by rw [show (4 : ℝ) = 2 ^ 2 by norm_num, Real.sqrt_sq (by norm_num)]
  norm_num [rangeValue, holdings, r4]

/-- A1, A3, A4: range [1, 4] (√prices in X96) at √price 2, a position of 10 liquidity in 2 units: one unit holds
1 token0 and 5 token1, both hold 2 and 10. -/
theorem slices :
    amountsAt Q96 (4 * Q96) 10 1 2 (2 * Q96) = some (1, 5) ∧
      amountsAt Q96 (4 * Q96) 10 2 2 (2 * Q96) = some (2, 10) := by
  decide

end Senzu.Witness
