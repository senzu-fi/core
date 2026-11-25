import Senzu.Proofs.Conversions
import Senzu.Proofs.Lenders

/-! # M1, W1–W4: bad debt and solvency -/

namespace Senzu.Proofs

open Spec

theorem marketStep_cash {m m' : Market} {act : MarketAction} (hm : m.totalBorrowAssets ≤ m.totalSupplyAssets)
    (h : marketStep writeOff m act = some m') : m'.totalBorrowAssets ≤ m'.totalSupplyAssets := by
  cases act with
  | supply x =>
    simp only [marketStep, Option.pure_def, Option.some.injEq] at h
    subst h
    dsimp only
    omega
  | withdraw a =>
    simp only [marketStep, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq] at h
    obtain ⟨cash, hcash, u, hok, rfl⟩ := h
    obtain ⟨-, rfl⟩ := sub_some hcash
    have := require_some hok
    dsimp only
    omega
  | borrow d fee ss =>
    simp only [marketStep, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq] at h
    obtain ⟨⟨q, fs, m₁⟩, hd, rfl⟩ := h
    obtain ⟨hle, -, rfl⟩ := addDebt_some hd
    dsimp only
    omega
  | repay q x =>
    simp only [marketStep, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
    obtain ⟨-, -, r, -, hr⟩ := h
    obtain ⟨booked, -, -, hle, rfl⟩ := repay_some hr
    dsimp only
    omega
  | writeOff q =>
    simp only [marketStep, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq] at h
    obtain ⟨-, -, ⟨debt, m₁⟩, hw, rfl⟩ := h
    obtain ⟨-, -, rfl⟩ := writeOff_some hw
    have := writeOffLoss_le m q debt
    dsimp only
    omega
  | accrue i =>
    simp only [marketStep, Option.pure_def, Option.some.injEq] at h
    subst h
    dsimp only
    omega

theorem cashNeverNegative : CashNeverNegative writeOff := by
  intro m acts
  induction acts generalizing m with
  | nil =>
    intro m' hm h
    simp only [marketRun, Option.pure_def, Option.some.injEq] at h
    exact h ▸ hm
  | cons act rest ih =>
    intro m' hm h
    simp only [marketRun, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
    obtain ⟨m₁, h₁, h₂⟩ := h
    exact ih m₁ m' (marketStep_cash hm h₁) h₂

/-- Lenders lose at most `debt`: the loss is capped and `totalSupplyAssets` stops at 0. -/
theorem loss_le {S debt B : ℕ} : (S : ℚ) - ((S - min debt B : ℕ) : ℚ) ≤ debt := by
  have h : ((S : ℕ) : ℚ) ≤ ((S - min debt B + debt : ℕ) : ℚ) := Nat.cast_le.mpr (by omega)
  rw [Nat.cast_add] at h
  linarith

theorem writeOffCostsAtMostTheDebt : WriteOffCostsAtMostTheDebt writeOff := by
  intro m q debt m' h hlt
  obtain ⟨ha, -, rfl⟩ := writeOff_some h
  rw [writeOffLoss_lt hlt]
  have := (ceil_rat (vs_pos _) (toAssets_up ha)).2
  rw [← exactAssets_eq] at this
  have := @loss_le m.totalSupplyAssets debt m.totalBorrowAssets
  dsimp only
  linarith

theorem borrowThenWriteOff : BorrowThenWriteOff writeOff := by
  intro m d fee ss minted fs m₁ debt m₂ hd hw hnone
  obtain ⟨-, hm, rfl⟩ := addDebt_some hd
  obtain ⟨ha, -, rfl⟩ := writeOff_some hw
  dsimp only at ha ⊢
  have hpr : (0 : ℚ) ≤ debtPrice m := by unfold debtPrice sharePrice; positivity
  by_cases hS : m.totalBorrowShares = 0
  · -- the only borrower: the write-off takes all the market's debt, which is what was just borrowed
    have hA := hnone hS
    unfold writeOffLoss
    rw [ite_eq_left_of_eq_true _ _ (eq_true (show minted = m.totalBorrowShares + minted by omega))]
    simp only [hA, Nat.zero_add]
    have : ((m.totalSupplyAssets + fee - (d + fee) : ℕ) : ℚ) ≥ m.totalSupplyAssets - d := by
      rcases Nat.lt_or_ge (m.totalSupplyAssets + fee) (d + fee) with h | h
      · rw [Nat.sub_eq_zero_of_le h.le]; push_cast; linarith [show (m.totalSupplyAssets : ℚ) < d by exact_mod_cast (by omega : m.totalSupplyAssets < d)]
      · rw [Nat.cast_sub h]; push_cast; linarith
    linarith
  have hlt : minted < m.totalBorrowShares + minted := by omega
  rw [writeOffLoss_lt (m := ⟨_, _, m.totalBorrowShares + minted⟩) hlt]
  obtain ⟨-, h1⟩ := ceil_bounds (va_pos _) (toShares_up hm)
  obtain ⟨-, h2⟩ := ceil_bounds (vs_pos _) (toAssets_up ha)
  set B := m.totalBorrowAssets
  set N := m.totalBorrowShares
  have h1q : ((minted * (B + VIRTUAL_ASSETS) : ℕ) : ℚ) <
      (((d + fee) * (N + VIRTUAL_SHARES) + (B + VIRTUAL_ASSETS) : ℕ) : ℚ) := Nat.cast_lt.mpr h1
  have h2q : ((debt * (N + minted + VIRTUAL_SHARES) : ℕ) : ℚ) <
      ((minted * (B + (d + fee) + VIRTUAL_ASSETS) + (N + minted + VIRTUAL_SHARES) : ℕ) : ℚ) :=
    Nat.cast_lt.mpr h2
  push_cast at h1q h2q
  have hN : (0 : ℚ) < ((N + VIRTUAL_SHARES : ℕ) : ℚ) := Nat.cast_pos.mpr (vs_pos N)
  have hD : (0 : ℚ) < ((B + VIRTUAL_ASSETS : ℕ) : ℚ) := Nat.cast_pos.mpr (va_pos B)
  push_cast at hN hD
  have key : ((debt : ℚ) - (d + fee) - 1) * ((N + VIRTUAL_SHARES) + minted) < B + VIRTUAL_ASSETS := by
    nlinarith
  have hlt := mul_lt_of_mul_add_lt hN (Nat.cast_nonneg minted) hD key
  have hfrac : (debt : ℚ) - (d + fee) - 1 < ((B + VIRTUAL_ASSETS : ℕ) : ℚ) / ((N + VIRTUAL_SHARES : ℕ) : ℚ) := by
    rw [lt_div_iff₀ (Nat.cast_pos.mpr (vs_pos N))]
    push_cast
    exact hlt
  have hloss : (m.totalSupplyAssets : ℚ) - ((m.totalSupplyAssets + fee - min debt (B + (d + fee)) : ℕ) : ℚ) ≤
      debt - fee := by
    have h : ((m.totalSupplyAssets + fee : ℕ) : ℚ) ≤
        ((m.totalSupplyAssets + fee - min debt (B + (d + fee)) + debt : ℕ) : ℚ) :=
      Nat.cast_le.mpr (by omega)
    push_cast at h
    linarith
  rw [debtPrice, sharePrice]
  linarith

theorem writeOffChargesNoOneElse : WriteOffChargesNoOneElse writeOff := by
  intro m q debt m' h hdebt hlt
  obtain ⟨ha, hq, rfl⟩ := writeOff_some h
  rw [writeOffLoss_lt hlt, min_eq_left hdebt]
  obtain ⟨h1, -⟩ := ceil_bounds (vs_pos _) (toAssets_up ha)
  rw [debtPrice, debtPrice, sharePrice_le_iff]
  dsimp only
  obtain ⟨A, hA⟩ := Nat.exists_eq_add_of_le hdebt
  obtain ⟨S, hS⟩ := Nat.exists_eq_add_of_le hq
  rw [hA, hS] at h1 ⊢
  rw [Nat.add_sub_cancel_left, Nat.add_sub_cancel_left]
  nlinarith

theorem lastWriteOffLeavesNoDebt : LastWriteOffLeavesNoDebt writeOff := by
  intro m debt m' h
  obtain ⟨-, -, rfl⟩ := writeOff_some h
  unfold writeOffLoss
  simp

end Senzu.Proofs
