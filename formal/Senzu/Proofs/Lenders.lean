import Senzu.Proofs.Model

/-! # L1–L5: lenders -/

namespace Senzu.Proofs

open Spec

theorem sharePrice_le_iff (a s a' s' : ℕ) :
    sharePrice a s ≤ sharePrice a' s' ↔
      (a + VIRTUAL_ASSETS) * (s' + VIRTUAL_SHARES) ≤ (a' + VIRTUAL_ASSETS) * (s + VIRTUAL_SHARES) := by
  have hn : (0 : ℚ) < ((s + VIRTUAL_SHARES : ℕ) : ℚ) := Nat.cast_pos.mpr (vs_pos s)
  have hn' : (0 : ℚ) < ((s' + VIRTUAL_SHARES : ℕ) : ℚ) := Nat.cast_pos.mpr (vs_pos s')
  rw [sharePrice, sharePrice, div_le_div_iff₀ hn hn', ← Nat.cast_mul, ← Nat.cast_mul, Nat.cast_le]

/-- If `t` per share over `n + m` shares stays below `d`, it does over `n`. -/
theorem mul_lt_of_mul_add_lt {t n m d : ℚ} (hn : 0 < n) (hm : 0 ≤ m) (hd : 0 < d) (h : t * (n + m) < d) :
    t * n < d := by
  rcases le_or_gt 0 t with ht | ht
  · nlinarith [mul_nonneg ht hm]
  · nlinarith

theorem supplyWithdrawRoundTrip : SupplyWithdrawRoundTrip senzu := by
  intro x a s minted back hm hb
  obtain ⟨h1, -⟩ := floor_bounds (va_pos a) (toShares_down hm)
  obtain ⟨h2, -⟩ := floor_bounds (vs_pos (s + minted)) (toAssets_down hb)
  have : back * (s + minted + VIRTUAL_SHARES) ≤ x * (s + minted + VIRTUAL_SHARES) := by nlinarith
  exact Nat.le_of_mul_le_mul_right this (vs_pos _)

theorem roundTripLoss : RoundTripLoss senzu := by
  intro x a s minted back hm hb
  obtain ⟨-, h1⟩ := floor_bounds (va_pos a) (toShares_down hm)
  obtain ⟨-, h2⟩ := floor_bounds (vs_pos (s + minted)) (toAssets_down hb)
  have h1q : (x : ℚ) * (s + VIRTUAL_SHARES) < minted * (a + VIRTUAL_ASSETS) + (a + VIRTUAL_ASSETS) := by
    exact_mod_cast h1
  have h2q : (minted : ℚ) * (a + x + VIRTUAL_ASSETS) <
      back * (s + minted + VIRTUAL_SHARES) + (s + minted + VIRTUAL_SHARES) := by
    exact_mod_cast h2
  have hn : (0 : ℚ) < s + VIRTUAL_SHARES := by exact_mod_cast vs_pos s
  have hd : (0 : ℚ) < a + VIRTUAL_ASSETS := by exact_mod_cast va_pos a
  have key : ((x : ℚ) - back - 1) * ((s + VIRTUAL_SHARES) + minted) < a + VIRTUAL_ASSETS := by nlinarith
  have := mul_lt_of_mul_add_lt hn (Nat.cast_nonneg minted) hd key
  rw [sharePrice, ← sub_lt_iff_lt_add, lt_div_iff₀ (by exact_mod_cast vs_pos s)]
  push_cast
  linarith

theorem priceNeverFalls : PriceNeverFalls senzu := by
  intro p act p' out h
  rw [sharePrice_le_iff]
  cases act with
  | supply x =>
    obtain ⟨m, hm, rfl, -⟩ := step_supply h
    obtain ⟨h1, -⟩ := floor_bounds (va_pos _) (toShares_down hm)
    dsimp only
    nlinarith
  | withdraw s =>
    obtain ⟨hs, a, ha, hle, rfl, -⟩ := step_withdraw h
    obtain ⟨h1, -⟩ := floor_bounds (vs_pos _) (toAssets_down ha)
    obtain ⟨A, hA⟩ := Nat.exists_eq_add_of_le hle
    obtain ⟨S, hS⟩ := Nat.exists_eq_add_of_le hs
    dsimp only
    rw [hA, hS] at h1 ⊢
    rw [Nat.add_sub_cancel_left, Nat.add_sub_cancel_left]
    nlinarith
  | accrue i =>
    obtain ⟨rfl, -⟩ := step_accrue h
    dsimp only
    nlinarith

theorem priceNeverFallsOverAnySequence_of {l : Lending} (h : PriceNeverFalls l) :
    PriceNeverFallsOverAnySequence l := by
  intro p acts
  induction acts generalizing p with
  | nil =>
    intro p' out hr
    obtain ⟨rfl, -⟩ := run_nil hr
    exact le_rfl
  | cons act rest ih =>
    intro p' out hr
    obtain ⟨p₁, o₁, o₂, h₁, h₂, -⟩ := run_cons hr
    exact (h _ _ _ _ h₁).trans (ih p₁ p' o₂ h₂)

theorem priceNeverFallsOverAnySequence : PriceNeverFallsOverAnySequence senzu :=
  priceNeverFallsOverAnySequence_of priceNeverFalls

/-- Assets only move by what is paid out and the interest added, whatever the wiring. -/
theorem run_assets {l : Lending} {p p' : Pool} {acts : List LendAction} {out : ℤ}
    (h : l.run p acts = some (p', out)) : (p'.assets : ℤ) = p.assets - out + interestOf acts := by
  induction acts generalizing p out with
  | nil =>
    obtain ⟨rfl, rfl⟩ := run_nil h
    simp [interestOf]
  | cons act rest ih =>
    obtain ⟨p₁, o₁, o₂, h₁, h₂, rfl⟩ := run_cons h
    have := ih h₂
    cases act with
    | supply x =>
      obtain ⟨m, -, rfl, rfl⟩ := step_supply h₁
      simp only [interestOf] at this ⊢
      push_cast at this
      omega
    | withdraw s =>
      obtain ⟨-, a, -, hle, rfl, rfl⟩ := step_withdraw h₁
      simp only [interestOf] at this ⊢
      omega
    | accrue i =>
      obtain ⟨rfl, rfl⟩ := step_accrue h₁
      simp only [interestOf] at this ⊢
      push_cast at this ⊢
      omega

theorem noFreeLunch : NoFreeLunch senzu := by
  intro p acts p' out h
  have hp := (sharePrice_le_iff _ _ _ _).1 (priceNeverFallsOverAnySequence p acts p' out h)
  have hc := run_assets h
  have hcq : (p'.assets : ℚ) = p.assets - out + interestOf acts := by exact_mod_cast hc
  have hpq : ((p.assets : ℚ) + VIRTUAL_ASSETS) * (p'.shares + VIRTUAL_SHARES) ≤
      (p'.assets + VIRTUAL_ASSETS) * (p.shares + VIRTUAL_SHARES) := by exact_mod_cast hp
  rw [hcq] at hpq
  have hn : (0 : ℚ) < ((p.shares + VIRTUAL_SHARES : ℕ) : ℚ) := by exact_mod_cast vs_pos p.shares
  rw [sharePrice, div_mul_eq_mul_div, ← sub_le_iff_le_add, le_div_iff₀ hn]
  push_cast
  linarith

end Senzu.Proofs
