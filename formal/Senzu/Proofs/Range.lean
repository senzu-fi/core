import Senzu.Proofs.Basic

/-!
# A1, A3, A4: what `amountsAt` reports

A successful `amountsAt` is a closed form (`amount0Of`, `amount1Of`) of the slice's liquidity, rounded down: each
amount is ⌊L·K / D⌋ for a K and D fixed by the range and the √price. A1 compares that floor with the exact `L·K/D`,
A4 adds floors, A3 bounds every intermediate value.
-/

namespace Senzu.Proofs

open Spec

/-- Token0 that liquidity `L` holds at √price `s` in `[lo, hi]`, rounded as `getAmountsForLiquidity` does. -/
def amount0Of (lo hi L s : ℕ) : ℕ :=
  if s ≤ lo then L * Q96 * (hi - lo) / hi / lo else if s < hi then L * Q96 * (hi - s) / hi / s else 0

/-- Token1, the same way. -/
def amount1Of (lo hi L s : ℕ) : ℕ :=
  if s ≤ lo then 0 else if s < hi then L * (s - lo) / Q96 else L * (hi - lo) / Q96

theorem amount0Delta_down {a b L r : ℕ} (h : amount0Delta a b L .down = some r) :
    r = L * Q96 * (max a b - min a b) / max a b / min a b := by
  unfold amount0Delta require at h
  by_cases h0 : min a b ≠ 0
  · cases hm : mulDiv (L * Q96) (max a b - min a b) (max a b) with
    | none => simp [h0, hm] at h
    | some m =>
      simp only [h0, hm, ne_eq, not_false_eq_true, ite_true, Option.bind_eq_bind, Option.bind_some,
        Option.pure_def, Option.some.injEq] at h
      rw [← h, mulDiv_some hm]
  · simp [h0] at h

theorem amount1Delta_down {a b L r : ℕ} (h : amount1Delta a b L .down = some r) :
    r = L * (max a b - min a b) / Q96 :=
  mulDiv_some h

theorem amountsForLiquidity_some {s a b L x y : ℕ} (h : amountsForLiquidity s a b L = some (x, y)) :
    x = amount0Of (min a b) (max a b) L s ∧ y = amount1Of (min a b) (max a b) L s := by
  unfold amountsForLiquidity at h
  unfold amount0Of amount1Of
  have hle : min a b ≤ max a b := min_le_max
  split_ifs at h ⊢ with h1 h2
  · obtain ⟨r, h0, hr⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at hr
    obtain ⟨rfl, rfl⟩ := hr
    rw [amount0Delta_down h0, max_eq_right hle, min_eq_left hle]
    exact ⟨rfl, rfl⟩
  · cases h0 : amount0Delta s (max a b) L .down with
    | none => simp [h0] at h
    | some r =>
      cases h1' : amount1Delta (min a b) s L .down with
      | none => simp [h0, h1'] at h
      | some r' =>
        simp only [h0, h1', Option.bind_eq_bind, Option.bind_some, Option.pure_def, Option.some.injEq,
          Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        have hs : min a b ≤ s := (not_le.1 h1).le
        rw [amount0Delta_down h0, amount1Delta_down h1', max_eq_right h2.le, min_eq_left h2.le,
          max_eq_right hs, min_eq_left hs]
        exact ⟨rfl, rfl⟩
  · obtain ⟨r, h0, hr⟩ := Option.map_eq_some_iff.1 h
    simp only [Prod.mk.injEq] at hr
    obtain ⟨rfl, rfl⟩ := hr
    rw [amount1Delta_down h0, max_eq_right hle, min_eq_left hle]
    exact ⟨rfl, rfl⟩

/-- What a successful `amountsAt` reported: the closed form of the slice's liquidity `L`. -/
theorem amountsAt_some {a b T u N s x y : ℕ} (h : amountsAt a b T u N s = some (x, y)) :
    ∃ L, liquidityOf u T N = some L ∧
      x = amount0Of (min a b) (max a b) L s ∧ y = amount1Of (min a b) (max a b) L s := by
  unfold amountsAt at h
  cases hL : liquidityOf u T N with
  | none => simp [hL] at h
  | some L =>
    simp only [hL, Option.bind_eq_bind, Option.bind_some] at h
    refine ⟨L, rfl, ?_⟩
    unfold rangeAt at h
    split_ifs at h with h0
    · subst h0
      simp only [Option.some.injEq, Prod.mk.injEq] at h
      obtain ⟨rfl, rfl⟩ := h
      simp [amount0Of, amount1Of]
    · exact amountsForLiquidity_some h

theorem liquidityOf_some {u T N L : ℕ} (h : liquidityOf u T N = some L) : L = if N = 0 then 0 else u * T / N := by
  unfold liquidityOf at h
  split_ifs at h with hN
  · simp only [hN, ↓reduceIte]; exact (Option.some.inj h).symm
  · cases hm : mulDiv u T N with
    | none => simp [hm] at h
    | some m =>
      simp only [hm, Option.bind_eq_bind, Option.bind_some, toU128] at h
      split_ifs at h
      simp only [hN, ↓reduceIte]
      rw [← Option.some.inj h, mulDiv_some hm]

/-! ## A4 -/

theorem div_div_superadditive (K D E : ℕ) {L₁ L₂ L : ℕ} (h : L₁ + L₂ ≤ L) :
    L₁ * K / D / E + L₂ * K / D / E ≤ L * K / D / E :=
  calc L₁ * K / D / E + L₂ * K / D / E ≤ (L₁ * K / D + L₂ * K / D) / E := Nat.div_add_div_le_add_div
    _ ≤ (L₁ * K + L₂ * K) / D / E := Nat.div_le_div_right (Nat.div_add_div_le_add_div)
    _ ≤ L * K / D / E := by
      apply Nat.div_le_div_right; apply Nat.div_le_div_right
      rw [← add_mul]; exact Nat.mul_le_mul_right _ h

theorem amount0Of_superadditive (lo hi s : ℕ) {L₁ L₂ L : ℕ} (h : L₁ + L₂ ≤ L) :
    amount0Of lo hi L₁ s + amount0Of lo hi L₂ s ≤ amount0Of lo hi L s := by
  unfold amount0Of
  split_ifs
  · simp only [mul_assoc]; exact div_div_superadditive _ _ _ h
  · simp only [mul_assoc]; exact div_div_superadditive _ _ _ h
  · simp

theorem amount1Of_superadditive (lo hi s : ℕ) {L₁ L₂ L : ℕ} (h : L₁ + L₂ ≤ L) :
    amount1Of lo hi L₁ s + amount1Of lo hi L₂ s ≤ amount1Of lo hi L s := by
  unfold amount1Of
  split_ifs
  · simp
  · simpa only [Nat.div_one] using div_div_superadditive (s - lo) Q96 1 h
  · simpa only [Nat.div_one] using div_div_superadditive (hi - lo) Q96 1 h

theorem splittingAddsNothing : SplittingAddsNothing amountsAt := by
  intro a b T u v N s x₁ y₁ x₂ y₂ x y _ h₁ h₂ h
  obtain ⟨L₁, hL₁, rfl, rfl⟩ := amountsAt_some h₁
  obtain ⟨L₂, hL₂, rfl, rfl⟩ := amountsAt_some h₂
  obtain ⟨L, hL, rfl, rfl⟩ := amountsAt_some h
  have hsum : L₁ + L₂ ≤ L := by
    rw [liquidityOf_some hL₁, liquidityOf_some hL₂, liquidityOf_some hL]
    split_ifs
    · simp
    · rw [add_mul]; exact Nat.div_add_div_le_add_div
  exact ⟨amount0Of_superadditive _ _ _ hsum, amount1Of_superadditive _ _ _ hsum⟩

/-! ## A1 -/

/-- A floor of `n / d` is within 1 below the exact value. -/
theorem floor_div_bounds (n d : ℕ) (hd : 0 < d) :
    ((n / d : ℕ) : ℝ) ≤ (n : ℝ) / d ∧ (n : ℝ) / d < (n / d : ℕ) + 1 := by
  have hd' : (0 : ℝ) < d := by exact_mod_cast hd
  refine ⟨Nat.cast_div_le, ?_⟩
  rw [div_lt_iff₀ hd']
  exact_mod_cast lt_floor_succ_mul n d hd

/-- One amount: the floor of the floored slice's `L·K/D` against the exact slice's. -/
theorem component {Lf K D : ℕ} {Lr : ℝ} (hD : 0 < D) (h₁ : (Lf : ℝ) ≤ Lr) (h₂ : Lr < Lf + 1) :
    ((Lf * K / D : ℕ) : ℝ) ≤ Lr * ((K : ℝ) / D) ∧ Lr * ((K : ℝ) / D) < (Lf * K / D : ℕ) + (K : ℝ) / D + 1 := by
  have hk : 0 ≤ (K : ℝ) / D := by positivity
  obtain ⟨f₁, f₂⟩ := floor_div_bounds (Lf * K) D hD
  push_cast at f₁ f₂
  rw [mul_div_assoc] at f₁ f₂
  constructor
  · exact f₁.trans (mul_le_mul_of_nonneg_right h₁ hk)
  · nlinarith [mul_le_mul_of_nonneg_right h₂.le hk]

theorem neverOverReports : NeverOverReports amountsAt := by
  intro a b T u N s x y ha hab hN _ h
  obtain ⟨L, hL, rfl, rfl⟩ := amountsAt_some h
  rw [liquidityOf_some hL] at *
  simp only [hN.ne', ↓reduceIte] at *
  rw [min_eq_left hab.le, max_eq_right hab.le]
  set Lr : ℝ := (u : ℝ) * T / N
  obtain ⟨l₁, l₂⟩ := floor_div_bounds (u * T) N hN
  push_cast at l₁ l₂
  have hQ : (0 : ℝ) < Q96 := by unfold Q96; positivity
  have ha' : (0 : ℝ) < a := by exact_mod_cast ha
  have hb' : (0 : ℝ) < b := by exact_mod_cast ha.trans hab
  have cmp (m n : ℕ) : (m : ℝ) / Q96 ≤ (n : ℝ) / Q96 ↔ m ≤ n := by
    rw [div_le_div_iff_of_pos_right hQ]; exact Nat.cast_le
  have cmpLt (m n : ℕ) : (m : ℝ) / Q96 < (n : ℝ) / Q96 ↔ m < n := by
    rw [div_lt_div_iff_of_pos_right hQ]; exact Nat.cast_lt
  simp only [exactAt, oneLiquidityAt, holdings, amount0Of, amount1Of, cmp, cmpLt]
  set Lf := u * T / N
  split_ifs with h1 h2
  · -- at or below the range: all token0
    have k : (1 : ℝ) / ((a : ℝ) / Q96) - 1 / ((b : ℝ) / Q96) = ((Q96 * (b - a) : ℕ) : ℝ) / ((b * a : ℕ) : ℝ) := by
      push_cast [Nat.cast_sub hab.le]; field_simp
    rw [k, Nat.div_div_eq_div_mul, mul_assoc, one_mul]
    obtain ⟨c₁, c₂⟩ := component (K := Q96 * (b - a)) (D := b * a) (Nat.mul_pos (by omega) ha) l₁ l₂
    dsimp only
    refine ⟨c₁, by simp, c₂, by simp⟩
  · -- inside: both
    have hs : a < s := not_le.1 h1
    have hs' : (0 : ℝ) < s := by exact_mod_cast ha.trans hs
    have k0 : (1 : ℝ) / ((s : ℝ) / Q96) - 1 / ((b : ℝ) / Q96) = ((Q96 * (b - s) : ℕ) : ℝ) / ((b * s : ℕ) : ℝ) := by
      push_cast [Nat.cast_sub h2.le]; field_simp
    have k1 : (s : ℝ) / Q96 - (a : ℝ) / Q96 = ((s - a : ℕ) : ℝ) / ((Q96 : ℕ) : ℝ) := by
      push_cast [Nat.cast_sub hs.le]; ring
    rw [k0, k1, Nat.div_div_eq_div_mul, mul_assoc, one_mul, one_mul]
    obtain ⟨c₁, c₂⟩ := component (K := Q96 * (b - s)) (D := b * s) (Nat.mul_pos (by omega) (by omega)) l₁ l₂
    obtain ⟨d₁, d₂⟩ := component (K := s - a) (by unfold Q96; positivity : 0 < Q96) l₁ l₂
    dsimp only
    exact ⟨c₁, d₁, c₂, d₂⟩
  · -- at or above the range: all token1
    have k1 : (b : ℝ) / Q96 - (a : ℝ) / Q96 = ((b - a : ℕ) : ℝ) / ((Q96 : ℕ) : ℝ) := by
      push_cast [Nat.cast_sub hab.le]; ring
    rw [k1, one_mul]
    obtain ⟨d₁, d₂⟩ := component (K := b - a) (by unfold Q96; positivity : 0 < Q96) l₁ l₂
    dsimp only
    refine ⟨by simp, d₁, by simp, d₂⟩

/-! ## A3 -/

theorem mulDiv_eq {a b c : ℕ} (hc : c ≠ 0) (h : a * b / c < U256) : mulDiv a b c = some (a * b / c) := by
  simp [mulDiv, hc, h]

theorem neverReverts : NeverReverts amountsAt := by
  intro a b T u N s ha hab hb hs hT hu
  have hQ : Q96 * 2 ^ 128 < U256 := by unfold Q96 U256; norm_num
  -- the slice's liquidity fits in 128 bits
  obtain ⟨L, hL, hL128⟩ : ∃ L, liquidityOf u T N = some L ∧ L < U128 := by
    unfold liquidityOf
    split_ifs with hN
    · exact ⟨0, rfl, by unfold U128; norm_num⟩
    · have hle : u * T / N ≤ T :=
        Nat.div_le_of_le_mul (by calc u * T ≤ N * T := Nat.mul_le_mul_right _ hu
                                      _ = N * T := rfl)
      have h256 : u * T / N < U256 := by unfold U128 at hT; unfold U256; omega
      refine ⟨u * T / N, ?_, by omega⟩
      simp [mulDiv_eq hN h256, toU128, show u * T / N < U128 by omega]
  have hL' : L < 2 ^ 128 := by unfold U128 at hL128; exact hL128
  unfold amountsAt
  simp only [hL, Option.bind_eq_bind, Option.bind_some]
  unfold rangeAt
  split_ifs with h0
  · exact ⟨_, rfl⟩
  unfold amountsForLiquidity
  rw [min_eq_left hab.le, max_eq_right hab.le]
  have hb0 : b ≠ 0 := by omega
  -- every amount0 fits: ⌊L·2^96·(b − x) / b⌋ ≤ L·2^96
  have a0 (x : ℕ) (hx0 : x ≠ 0) (hxb : x ≤ b) : ∃ r, amount0Delta x b L .down = some r := by
    unfold amount0Delta require
    rw [min_eq_left hxb, max_eq_right hxb]
    have : L * Q96 * (b - x) / b < U256 := by
      have : L * Q96 * (b - x) / b ≤ L * Q96 :=
        Nat.div_le_of_le_mul (by rw [mul_comm b]; exact Nat.mul_le_mul_left _ (Nat.sub_le _ _))
      have : L * Q96 < Q96 * 2 ^ 128 := by rw [mul_comm]; exact Nat.mul_lt_mul_of_pos_left hL' (by unfold Q96; positivity)
      omega
    simp [hx0, mulDiv_eq hb0 this]
  -- every amount1 fits: L·(y − x) < 2^128 · 2^160, so ⌊L·(y − x) / 2^96⌋ < 2^192
  have a1 (x y : ℕ) (hxy : x ≤ y) (hy : y < U160) : ∃ r, amount1Delta x y L .down = some r := by
    unfold amount1Delta
    rw [max_eq_right hxy, min_eq_left hxy]
    have : L * (y - x) / Q96 < U256 := by
      have e1 : L * (y - x) ≤ L * U160 := Nat.mul_le_mul_left _ ((Nat.sub_le y x).trans hy.le)
      have e2 : L * U160 < 2 ^ 128 * U160 := Nat.mul_lt_mul_of_lt_of_le hL' le_rfl (by unfold U160; positivity)
      have e3 : 2 ^ 128 * U160 < U256 * Q96 := by unfold U160 U256 Q96; norm_num
      exact (Nat.div_lt_iff_lt_mul (by unfold Q96; positivity)).2 (e1.trans_lt (e2.trans e3))
    exact ⟨_, mulDiv_eq (by unfold Q96; positivity) this⟩
  split_ifs with h1 h2
  · obtain ⟨r, hr⟩ := a0 a (by omega) hab.le
    simp [hr]
  · obtain ⟨r, hr⟩ := a0 s (by omega) h2.le
    obtain ⟨r', hr'⟩ := a1 a s (by omega) hs
    simp [hr, hr']
  · obtain ⟨r', hr'⟩ := a1 a b hab.le hb
    simp [hr']

end Senzu.Proofs
