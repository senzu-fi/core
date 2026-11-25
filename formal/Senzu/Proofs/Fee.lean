import Senzu.Proofs.Liquidation

/-! # F1–F3: the liquidation fee -/

namespace Senzu.Proofs

open Spec

theorem minIncentive_pos : 0 < MIN_INCENTIVE := by unfold MIN_INCENTIVE; positivity

/-- What a fee that didn't revert computed: zero where F2 says, else `feeWad` of the rounded-down gain when it is
positive. -/
theorem liquidationFee_some {C D d P unit U s R w f : ℕ} {other : Bool}
    (h : liquidationFee C D d P unit U s R w other = some f) :
    ((w = 0 ∨ s = 0 ∨ C * WAD < MIN_INCENTIVE * D ∨ (s = U ∧ (R < d ∨ other = true))) ∧ f = 0) ∨
    (0 < w ∧ 0 < s ∧ MIN_INCENTIVE * D ≤ C * WAD ∧ ¬ (s = U ∧ (R < d ∨ other = true)) ∧ 0 < U ∧ 0 < P ∧
      ((R < C * s / U * unit / P ∧ f = (C * s / U * unit / P - R) * w / WAD) ∨
        (C * s / U * unit / P ≤ R ∧ f = 0))) := by
  unfold liquidationFee at h
  split_ifs at h with h0
  · exact Or.inl ⟨by tauto, (Option.some.inj h).symm⟩
  · simp only [Option.bind_eq_bind, Option.bind_eq_some_iff] at h
    obtain ⟨atFloor, hf, h⟩ := h
    obtain ⟨-, rfl⟩ := mulDiv_spec hf
    have hfloor : C * WAD / MIN_INCENTIVE < D ↔ C * WAD < MIN_INCENTIVE * D := by
      rw [Nat.div_lt_iff_lt_mul minIncentive_pos, Nat.mul_comm D]
    split_ifs at h with h1
    · refine Or.inl ⟨?_, (Option.some.inj h).symm⟩
      rcases h1 with h1 | h1
      · exact Or.inr (Or.inr (Or.inl (hfloor.mp h1)))
      · exact Or.inr (Or.inr (Or.inr h1))
    · obtain ⟨h1a, h1b⟩ := not_or.mp h1
      obtain ⟨hw, hs⟩ := not_or.mp h0
      simp only [Option.bind_eq_some_iff] at h
      obtain ⟨usd, hu, sA, hsA, h⟩ := h
      obtain ⟨hU, rfl⟩ := mulDiv_spec hu
      obtain ⟨hP, rfl⟩ := mulDiv_spec hsA
      refine Or.inr ⟨Nat.pos_of_ne_zero hw, Nat.pos_of_ne_zero hs, Nat.le_of_not_lt (fun h' => h1a (hfloor.mpr h')),
        h1b, hU, hP, ?_⟩
      split_ifs at h with h2
      · obtain ⟨-, rfl⟩ := mulDiv_spec h
        exact Or.inl ⟨h2, rfl⟩
      · exact Or.inr ⟨Nat.le_of_not_lt h2, (Option.some.inj h).symm⟩

/-- The seized units' worth in the repaid asset, rounded down twice, is at most the exact worth, and over it less
one USD-wei in the asset and 1 wei. -/
theorem seizedAssets_bounds {C s U unit P : ℕ} (hU : 0 < U) (hP : 0 < P) :
    ((C * s / U * unit / P : ℕ) : ℚ) ≤ (s : ℚ) * C / U * unit / P ∧
      (s : ℚ) * C / U * unit / P - ((unit : ℚ) / P + 1) < ((C * s / U * unit / P : ℕ) : ℚ) := by
  have hU' : (0 : ℚ) < U := by exact_mod_cast hU
  have hP' : (0 : ℚ) < P := by exact_mod_cast hP
  obtain ⟨lu, hu⟩ := floor_bounds hU (rfl : C * s / U = C * s / U)
  obtain ⟨la, ha⟩ := floor_bounds hP (rfl : C * s / U * unit / P = C * s / U * unit / P)
  have lu' : ((C * s / U : ℕ) : ℚ) * U ≤ (s : ℚ) * C := by
    have := (Nat.cast_le (α := ℚ)).mpr lu; push_cast at this; linarith
  have hu' : (s : ℚ) * C < ((C * s / U : ℕ) : ℚ) * U + U := by
    have := (Nat.cast_lt (α := ℚ)).mpr hu; push_cast at this; linarith
  have la' : ((C * s / U * unit / P : ℕ) : ℚ) * P ≤ ((C * s / U : ℕ) : ℚ) * unit := by
    have := (Nat.cast_le (α := ℚ)).mpr la; push_cast at this; linarith
  have ha' : ((C * s / U : ℕ) : ℚ) * unit < ((C * s / U * unit / P : ℕ) : ℚ) * P + P := by
    have := (Nat.cast_lt (α := ℚ)).mpr ha; push_cast at this; linarith
  have usd_le : ((C * s / U : ℕ) : ℚ) ≤ (s : ℚ) * C / U := by rw [le_div_iff₀ hU']; linarith
  have usd_gt : (s : ℚ) * C / U < ((C * s / U : ℕ) : ℚ) + 1 := by rw [div_lt_iff₀ hU']; linarith
  have hunit : (0 : ℚ) ≤ unit := by positivity
  constructor
  · rw [le_div_iff₀ hP']
    calc ((C * s / U * unit / P : ℕ) : ℚ) * P ≤ ((C * s / U : ℕ) : ℚ) * unit := la'
      _ ≤ (s : ℚ) * C / U * unit := mul_le_mul_of_nonneg_right usd_le hunit
  · have step : (s : ℚ) * C / U * unit / P ≤ ((C * s / U : ℕ) : ℚ) * unit / P + (unit : ℚ) / P := by
      rw [← add_div]
      exact div_le_div_of_nonneg_right
        (by nlinarith [mul_le_mul_of_nonneg_right usd_gt.le hunit]) hP'.le
    have step2 : ((C * s / U : ℕ) : ℚ) * unit / P < ((C * s / U * unit / P : ℕ) : ℚ) + 1 := by
      rw [div_lt_iff₀ hP']; linarith
    linarith

/-- **F1.** -/
theorem feeAtMostShareOfGain : FeeAtMostShareOfGain liquidationFee := by
  intro C D d P unit U s R w other f h
  have hk : (0 : ℚ) ≤ (w : ℚ) / WAD := by positivity
  have hmax : (0 : ℚ) ≤ (w : ℚ) / WAD * max 0 ((s : ℚ) * C / U * unit / P - R) :=
    mul_nonneg hk (le_max_left _ _)
  rcases liquidationFee_some h with ⟨-, rfl⟩ | ⟨-, -, -, -, hU, hP, ⟨hR, rfl⟩ | ⟨-, rfl⟩⟩
  · simpa using hmax
  · have hle := (seizedAssets_bounds (C := C) (s := s) (unit := unit) hU hP).1
    have hf : (((C * s / U * unit / P - R) * w / WAD : ℕ) : ℚ) ≤
        (((C * s / U * unit / P - R) * w : ℕ) : ℚ) / WAD := Nat.cast_div_le
    rw [Nat.cast_mul, Nat.cast_sub hR.le] at hf
    calc _ ≤ _ := hf
      _ = (w : ℚ) / WAD * (((C * s / U * unit / P : ℕ) : ℚ) - R) := by ring
      _ ≤ (w : ℚ) / WAD * max 0 ((s : ℚ) * C / U * unit / P - R) :=
        mul_le_mul_of_nonneg_left (le_trans (by linarith) (le_max_right _ _)) hk
  · simpa using hmax

/-- **F2.** -/
theorem noFeeOnBadDebt : NoFeeOnBadDebt liquidationFee := by
  intro C D d P unit U s R w other f h
  rcases liquidationFee_some h with ⟨-, rfl⟩ | ⟨-, -, hD, hn, -, -, -⟩
  · exact ⟨fun _ => rfl, fun _ _ => rfl⟩
  · exact ⟨fun h' => absurd hD (not_le.mpr h'), fun hs hR => absurd ⟨hs, hR⟩ hn⟩

/-- **F3.** -/
theorem feeLosesOnlyRounding : FeeLosesOnlyRounding liquidationFee := by
  intro C D d P unit U s R w other f hw hs hD hn h
  rcases liquidationFee_some h with ⟨hz, -⟩ | ⟨-, -, -, -, hU, hP, hcase⟩
  · exfalso
    rcases hz with hz | hz | hz | hz
    · omega
    · omega
    · exact absurd hD (not_le.mpr hz)
    · exact hn hz
  have hk : (0 : ℚ) ≤ (w : ℚ) / WAD := by positivity
  have hgt := (seizedAssets_bounds (C := C) (s := s) (unit := unit) hU hP).2
  -- the bound is at most `feeWad` of the rounded-down gain, less 1
  have hle : (w : ℚ) / WAD * ((s : ℚ) * C / U * unit / P - R) - (w : ℚ) / WAD * ((unit : ℚ) / P + 1) - 1 ≤
      (w : ℚ) / WAD * (((C * s / U * unit / P : ℕ) : ℚ) - R) - 1 := by
    have := mul_le_mul_of_nonneg_left (show (s : ℚ) * C / U * unit / P - R - ((unit : ℚ) / P + 1) ≤
      ((C * s / U * unit / P : ℕ) : ℚ) - R by linarith) hk
    linarith
  rcases hcase with ⟨hR, rfl⟩ | ⟨hR, rfl⟩
  · obtain ⟨-, hf⟩ := floor_bounds wad_pos
      (rfl : (C * s / U * unit / P - R) * w / WAD = (C * s / U * unit / P - R) * w / WAD)
    have hf' : (((C * s / U * unit / P - R) * w : ℕ) : ℚ) <
        (((C * s / U * unit / P - R) * w / WAD : ℕ) : ℚ) * WAD + WAD := by exact_mod_cast hf
    rw [Nat.cast_mul, Nat.cast_sub hR.le] at hf'
    have hW : (0 : ℚ) < WAD := by exact_mod_cast wad_pos
    have : (w : ℚ) / WAD * (((C * s / U * unit / P : ℕ) : ℚ) - R) <
        (((C * s / U * unit / P - R) * w / WAD : ℕ) : ℚ) + 1 := by
      rw [div_mul_eq_mul_div, div_lt_iff₀ hW]; linarith
    linarith
  · have hR' : ((C * s / U * unit / P : ℕ) : ℚ) ≤ R := by exact_mod_cast hR
    have := mul_nonpos_of_nonneg_of_nonpos hk (show ((C * s / U * unit / P : ℕ) : ℚ) - R ≤ 0 by linarith)
    push_cast
    linarith

end Senzu.Proofs
