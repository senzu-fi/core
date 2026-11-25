import Senzu.Proofs.Model

/-! # B1, B2: borrowers -/

namespace Senzu.Proofs

open Spec

theorem borrowOwesAtLeastBorrowed : BorrowOwesAtLeastBorrowed senzu := by
  intro d a s minted owed hm ho
  obtain ⟨h1, -⟩ := ceil_bounds (va_pos a) (toShares_up hm)
  obtain ⟨h2, -⟩ := ceil_bounds (vs_pos (s + minted)) (toAssets_up ho)
  have : d * (s + minted + VIRTUAL_SHARES) ≤ owed * (s + minted + VIRTUAL_SHARES) := by nlinarith
  exact Nat.le_of_mul_le_mul_right this (vs_pos _)

theorem repayNeverOverCredits : RepayNeverOverCredits senzu := by
  intro x a s burned h
  obtain ⟨bought, -, hb, -, -, -, -, -, hr⟩ := repayBurns_spec h
  have h1 : burned * (a + VIRTUAL_ASSETS) ≤ x * (s + VIRTUAL_SHARES) :=
    le_trans (Nat.mul_le_mul_right _ hr) hb
  have hn : (0 : ℚ) < ((s + VIRTUAL_SHARES : ℕ) : ℚ) := Nat.cast_pos.mpr (vs_pos s)
  have h1q : ((burned * (a + VIRTUAL_ASSETS) : ℕ) : ℚ) ≤ ((x * (s + VIRTUAL_SHARES) : ℕ) : ℚ) :=
    Nat.cast_le.mpr h1
  rw [Nat.cast_mul, Nat.cast_mul] at h1q
  rw [sharePrice, mul_div_assoc', div_le_iff₀ hn]
  exact h1q

end Senzu.Proofs
