import Senzu.Proofs.Lenders

/-! # B3–B5: repayments -/

namespace Senzu.Proofs

open Spec

/-- What a repayment takes covers the shares it burns at the exact price. -/
theorem repayAmounts_covers {m : Market} {q x : ℕ} {r : ℕ × ℕ} (h : repayAmounts m q x = some r) :
    r.2 * (m.totalBorrowAssets + VIRTUAL_ASSETS) ≤ r.1 * (m.totalBorrowShares + VIRTUAL_SHARES) := by
  simp only [repayAmounts, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
  obtain ⟨-, -, debt, hd, h⟩ := h
  split_ifs at h
  · simp only [Option.some.injEq] at h
    subst h
    exact (ceil_bounds (vs_pos _) (toAssets_up hd)).1
  · simp only [Option.bind_eq_some_iff, Option.some.injEq] at h
    obtain ⟨-, -, sh, hsh, rfl⟩ := h
    obtain ⟨bought, -, hb, -, -, -, -, -, hr⟩ := repayBurns_spec hsh
    exact le_trans (Nat.mul_le_mul_right _ hr) hb

/-- The booking never passes the market's debt. -/
theorem booked_le {A S s b : ℕ} (hs : s ≤ S) (hb : b * (S + VIRTUAL_SHARES) ≤ s * (A + VIRTUAL_ASSETS)) :
    b ≤ A := by
  unfold VIRTUAL_SHARES VIRTUAL_ASSETS at hb
  by_contra hA
  have h1 : (A + 1) * (S + 1000000) ≤ b * (S + 1000000) := Nat.mul_le_mul_right _ (by omega)
  have h2 : s * (A + 1) ≤ S * (A + 1) := Nat.mul_le_mul_right _ hs
  nlinarith

/-- A repayment of shares that aren't the last books `b`, their worth rounded down; the last shares book all the
debt. Either way lenders get the rest of what it paid. -/
theorem repay_spec {m m' : Market} {s p : ℕ} (h : repay m s p = some m') :
    ∃ b, b ≤ m.totalBorrowAssets ∧ b ≤ m.totalSupplyAssets + p ∧ s ≤ m.totalBorrowShares ∧
      (s < m.totalBorrowShares →
        b * (m.totalBorrowShares + VIRTUAL_SHARES) ≤ s * (m.totalBorrowAssets + VIRTUAL_ASSETS)) ∧
      (s = m.totalBorrowShares → b = m.totalBorrowAssets) ∧
      m' = ⟨m.totalSupplyAssets + p - b, m.totalBorrowAssets - b, m.totalBorrowShares - s⟩ := by
  obtain ⟨b, hb, hs, hle, rfl⟩ := repay_some h
  unfold repayBooks at hb
  split_ifs at hb with he
  · obtain rfl := Option.some.inj hb
    exact ⟨_, le_refl _, hle, hs, fun h => absurd he (Nat.ne_of_lt h), fun _ => rfl, rfl⟩
  · have hf := (floor_bounds (vs_pos _) (toAssets_down hb)).1
    exact ⟨b, booked_le hs hf, hle, hs, fun _ => hf, fun h => absurd h he, rfl⟩

theorem repayNeverLowersDebtPrice : RepayNeverLowersDebtPrice repay := by
  intro m q x r m' _ _ hlt h
  obtain ⟨b, hbA, -, hs, hb, -, rfl⟩ := repay_spec h
  have hb := hb hlt
  rw [debtPrice, debtPrice, sharePrice_le_iff]
  dsimp only
  obtain ⟨a, ha⟩ := Nat.exists_eq_add_of_le hbA
  obtain ⟨t, ht⟩ := Nat.exists_eq_add_of_le hs
  rw [ha, ht] at hb ⊢
  rw [Nat.add_sub_cancel_left, Nat.add_sub_cancel_left]
  unfold VIRTUAL_SHARES VIRTUAL_ASSETS at hb ⊢
  nlinarith

theorem repayPaysLenders : RepayPaysLenders repay := by
  intro m q x r m' _ _ h
  obtain ⟨b, hbA, hbp, -, -, -, rfl⟩ := repay_spec h
  dsimp only
  omega

theorem lastRepayLeavesNoDebt : LastRepayLeavesNoDebt repay := by
  intro m q x r m' _ _ he h
  obtain ⟨b, -, -, -, -, hb, rfl⟩ := repay_spec h
  change m.totalBorrowAssets - b = 0
  rw [hb he]
  exact Nat.sub_self _

end Senzu.Proofs
