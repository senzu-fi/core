import Mathlib.Tactic.Ring
import Senzu.Proofs.Repayments

/-! # Q1–Q4: liquidations -/

namespace Senzu.Proofs

open Spec

theorem mulDiv_spec {a b c r : ℕ} (h : mulDiv a b c = some r) : 0 < c ∧ r = a * b / c := by
  unfold mulDiv at h
  split_ifs at h with hc
  exact ⟨Nat.pos_of_ne_zero hc, (Option.some.inj h).symm⟩

theorem mulDivUp_spec {a b c r : ℕ} (h : mulDivUp a b c = some r) : 0 < c ∧ r = (a * b + c - 1) / c := by
  unfold mulDivUp at h
  split_ifs at h with hc
  exact ⟨Nat.pos_of_ne_zero hc, (Option.some.inj h).symm⟩

theorem wad_pos : 0 < WAD := by unfold WAD; positivity

/-- The penalty borne is at least `MIN_INCENTIVE` and, for a position covered at `MIN_INCENTIVE`, at most collateral /
debt. -/
theorem bearable_spec {C D pen b : ℕ} (h : bearable C D pen = some b) (hpen : MIN_INCENTIVE ≤ pen) :
    MIN_INCENTIVE ≤ b ∧ b ≤ pen ∧ (MIN_INCENTIVE * D ≤ C * WAD → b * D ≤ C * WAD) := by
  unfold bearable at h
  split_ifs at h with hD
  · obtain rfl := Option.some.inj h
    subst hD
    exact ⟨hpen, le_refl _, fun _ => by simp⟩
  · simp only [Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq] at h
    obtain ⟨ratio, hr, rfl⟩ := h
    obtain ⟨-, rfl⟩ := mulDiv_spec hr
    have hD' : 0 < D := Nat.pos_of_ne_zero hD
    have hle : C * WAD / D * D ≤ C * WAD := Nat.div_mul_le_self _ _
    refine ⟨?_, ?_, fun hc => ?_⟩
    · split_ifs <;> omega
    · split_ifs <;> omega
    · have : MIN_INCENTIVE ≤ C * WAD / D := (Nat.le_div_iff_mul_le hD').mpr hc
      split_ifs with h1 h2
      · exact le_trans (Nat.mul_le_mul_right _ h1) hle
      · omega
      · exact hle

theorem liquidate_some {C D d P unit pen maxRepay U s R : ℕ}
    (h : senzuLiquidation.liquidate C D d P unit pen maxRepay U = some (s, R)) :
    C ≠ 0 ∧ d ≠ 0 ∧ ∃ b, bearable C D pen = some b ∧ seize U C (min maxRepay d) P unit b = some (s, R) := by
  by_cases hC : C = 0
  · simp [Liquidation.liquidate, require, hC] at h
  by_cases hd : d = 0
  · simp [Liquidation.liquidate, require, hd] at h
  have hr : min maxRepay d ≠ 0 := by
    intro h0
    simp [Liquidation.liquidate, require, hC, hd, h0] at h
  simp only [Liquidation.liquidate, senzuLiquidation, require, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
  obtain ⟨-, -, -, -, -, -, b, hb, hs⟩ := h
  exact ⟨hC, hd, b, hb, hs⟩

/-- A seize takes at most the units and repays at most what was offered, and the units it takes, times the
collateral's value, are worth at most the repayment × the penalty (in whole numbers: `s·C·unit·WAD ≤ U·R·P·b`). -/
theorem seize_spec {U C R P unit b s R' : ℕ} (h : seize U C R P unit b = some (s, R')) (hb : MIN_INCENTIVE ≤ b) :
    0 < unit ∧ s ≤ U ∧ R' ≤ R ∧ s * C * (unit * WAD) ≤ U * (R' * P * b) := by
  simp only [seize, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
  obtain ⟨rUsd, hr, x, hx, h⟩ := h
  obtain ⟨hu, hr⟩ := mulDiv_spec hr
  obtain ⟨-, hx⟩ := mulDiv_spec hx
  have fr := (floor_bounds hu hr).1
  have fx := (floor_bounds wad_pos hx).1
  -- what `x` is worth, in the repayment's terms
  have key : x * (unit * WAD) ≤ R * P * b := by
    calc x * (unit * WAD) = x * WAD * unit := by ring
      _ ≤ rUsd * b * unit := Nat.mul_le_mul_right _ fx
      _ = rUsd * unit * b := by ring
      _ ≤ R * P * b := Nat.mul_le_mul_right _ fr
  split_ifs at h with hcap
  · simp only [Option.bind_eq_some_iff, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨atMin, ha, cov, hc, rfl, rfl⟩ := h
    obtain ⟨-, ha⟩ := mulDivUp_spec ha
    obtain ⟨hP, hc⟩ := mulDivUp_spec hc
    have ca := (ceil_bounds (by unfold MIN_INCENTIVE; positivity) ha).1
    have cc := (ceil_bounds hP hc).1
    -- taking every unit: they were worth at most `x`
    have hCx : U * C ≤ U * x := Nat.mul_le_mul_left _ hcap
    refine ⟨hu, le_refl _, by split_ifs <;> omega, ?_⟩
    split_ifs with hlt
    · -- the repayment capped at what the collateral covers at `MIN_INCENTIVE`
      have : C * (unit * WAD) ≤ cov * P * b := by
        calc C * (unit * WAD) = C * WAD * unit := by ring
          _ ≤ atMin * MIN_INCENTIVE * unit := Nat.mul_le_mul_right _ ca
          _ ≤ atMin * b * unit := Nat.mul_le_mul_right _ (Nat.mul_le_mul_left _ hb)
          _ = atMin * unit * b := by ring
          _ ≤ cov * P * b := Nat.mul_le_mul_right _ cc
      calc U * C * (unit * WAD) = U * (C * (unit * WAD)) := by ring
        _ ≤ U * (cov * P * b) := Nat.mul_le_mul_left _ this
    · calc U * C * (unit * WAD) = (U * C) * (unit * WAD) := rfl
        _ ≤ (U * x) * (unit * WAD) := Nat.mul_le_mul_right _ hCx
        _ = U * (x * (unit * WAD)) := by ring
        _ ≤ U * (R * P * b) := Nat.mul_le_mul_left _ key
  · simp only [Option.bind_eq_some_iff, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨sd, hsd, rfl, rfl⟩ := h
    obtain ⟨hC, hsd⟩ := mulDiv_spec hsd
    have fs := floor_bounds hC hsd
    -- worth less than the collateral, so less than every unit
    have hsU : sd ≤ U :=
      Nat.le_of_mul_le_mul_right (le_trans fs.1 (Nat.mul_le_mul_left _ (Nat.le_of_lt (Nat.lt_of_not_le hcap)))) hC
    refine ⟨hu, hsU, le_refl _, ?_⟩
    calc sd * C * (unit * WAD) ≤ (U * x) * (unit * WAD) := Nat.mul_le_mul_right _ fs.1
      _ = U * (x * (unit * WAD)) := by ring
      _ ≤ U * (R * P * b) := Nat.mul_le_mul_left _ key

/-- Q1's value bound, as rationals. -/
theorem seized_value {U C R P unit b s : ℕ} (hu : 0 < unit) (hs : s * C * (unit * WAD) ≤ U * (R * P * b)) :
    (s : ℚ) * C / U ≤ (R : ℚ) * P / unit * b / WAD := by
  rcases Nat.eq_zero_or_pos U with rfl | hU
  · simp only [Nat.cast_zero, div_zero]
    positivity
  have hU' : (0 : ℚ) < U := by exact_mod_cast hU
  have hu' : (0 : ℚ) < unit := by exact_mod_cast hu
  have hw : (0 : ℚ) < WAD := by exact_mod_cast wad_pos
  have hs' : (s : ℚ) * C * (unit * WAD) ≤ U * (R * P * b) := by exact_mod_cast hs
  rw [div_mul_eq_mul_div, div_div, div_le_div_iff₀ hU' (by positivity)]
  linarith [hs', show (U : ℚ) * (R * P * b) = R * P * b * U by ring]

theorem liquidatorTakesNoMore : LiquidatorTakesNoMore senzuLiquidation := by
  intro C D d P unit pen maxRepay U s R b hpen h hb
  obtain ⟨-, -, b', hb', hs⟩ := liquidate_some h
  rw [show senzuLiquidation.bearable = bearable from rfl, hb'] at hb
  obtain rfl := Option.some.inj hb
  obtain ⟨hmin, -, -⟩ := bearable_spec hb' hpen
  obtain ⟨hu, hsU, hR, hv⟩ := seize_spec hs hmin
  exact ⟨le_trans hR (min_le_right _ _), le_trans hR (min_le_left _ _), hsU, seized_value hu hv⟩

/-! ## The debt a repayment leaves -/

theorem toAssets_zero_up {a s r : ℕ} (h : toAssets 0 a s .up = some r) : r = 0 := by
  rw [toAssets_up h, Nat.zero_mul, Nat.zero_add]
  exact Nat.div_eq_of_lt (Nat.sub_lt (vs_pos s) Nat.one_pos)

/-- Repaying `R` of a debt of `d` (the position's `q` shares, rounded up) leaves at most `d - R`, one borrow share's
price and 2 wei: the shares burned round down, and so does what the market books for them. -/
theorem debt_left {m m' : Market} {q d R d' : ℕ} {r : ℕ × ℕ} (hq : q ≤ m.totalBorrowShares)
    (hd : toAssets q m.totalBorrowAssets m.totalBorrowShares .up = some d) (hR : R ≤ d)
    (hr : repayAmounts m q R = some r) (hm : repay m r.2 r.1 = some m')
    (hd' : toAssets (q - r.2) m'.totalBorrowAssets m'.totalBorrowShares .up = some d') :
    r.1 = R ∧ (d' : ℚ) ≤ d - R + debtPrice m + 2 := by
  have hpr : (0 : ℚ) ≤ debtPrice m := by unfold debtPrice sharePrice; positivity
  simp only [repayAmounts, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff] at hr
  obtain ⟨-, -, debt, hdebt, hr⟩ := hr
  rw [hd] at hdebt
  obtain rfl := Option.some.inj hdebt
  split_ifs at hr with hle
  · obtain rfl := Option.some.inj hr
    obtain rfl : d = R := le_antisymm hle hR
    simp only [Nat.sub_self] at hd'
    obtain rfl := toAssets_zero_up hd'
    simp only [Nat.cast_zero, true_and]
    linarith
  simp only [Option.bind_eq_some_iff, Option.some.injEq] at hr
  obtain ⟨-, -, q', hq', rfl⟩ := hr
  refine ⟨rfl, ?_⟩
  dsimp only at hm hd' ⊢
  obtain ⟨booked, hbk, hqS, -, rfl⟩ := repay_some hm
  dsimp only at hd'
  set A := m.totalBorrowAssets
  set S := m.totalBorrowShares
  have hM : 0 < A + VIRTUAL_ASSETS := va_pos A
  have hN : 0 < S + VIRTUAL_SHARES := vs_pos S
  have cd := ceil_bounds hN (toAssets_up hd)
  obtain ⟨bought, c, b1, b2, c1, c2, r1, -, hqb⟩ := repayBurns_spec hq'
  -- the shares burned are fewer than the position's
  have hlt : q' < q := by
    have h1 : (R + 1) * (S + VIRTUAL_SHARES) ≤ d * (S + VIRTUAL_SHARES) := Nat.mul_le_mul_right _ (by omega)
    have : R * (S + VIRTUAL_SHARES) < q * (A + VIRTUAL_ASSETS) := by
      rw [Nat.succ_mul] at h1; linarith only [h1, cd.2]
    exact lt_of_le_of_lt hqb (Nat.lt_of_mul_lt_mul_right (lt_of_le_of_lt b1 this))
  have hne : q' ≠ S := by omega
  unfold repayBooks at hbk
  rw [ite_eq_right_of_eq_false _ _ (eq_false hne)] at hbk
  have fb := floor_bounds hN (toAssets_down hbk)
  have hbA := booked_le (s := q') hqS fb.1
  -- the market books at least the whole wei the payment clears
  have hcb : c ≤ booked := by
    have : c * (S + VIRTUAL_SHARES) < (booked + 1) * (S + VIRTUAL_SHARES) := by
      rw [Nat.succ_mul]; exact lt_of_le_of_lt r1 fb.2
    exact Nat.le_of_lt_succ (Nat.lt_of_mul_lt_mul_right this)
  have hN' : 0 < S - q' + VIRTUAL_SHARES := vs_pos _
  have cd' := ceil_bounds hN' (toAssets_up hd')
  unfold debtPrice sharePrice
  unfold VIRTUAL_SHARES VIRTUAL_ASSETS at *
  have ca : ((q * (A + 1) : ℕ) : ℚ) ≤ ((d * (S + 1000000) : ℕ) : ℚ) := by exact_mod_cast cd.1
  have qb2 : ((R * (S + 1000000) : ℕ) : ℚ) < ((bought * (A + 1) + (A + 1) : ℕ) : ℚ) := by exact_mod_cast b2
  have qc2 : ((bought * (A + 1) : ℕ) : ℚ) < ((c * (S + 1000000) + (S + 1000000) : ℕ) : ℚ) := by
    exact_mod_cast c2
  have fb1 : ((booked * (S + 1000000) : ℕ) : ℚ) ≤ ((q' * (A + 1) : ℕ) : ℚ) := by exact_mod_cast fb.1
  have cd2 : (((d' * (S - q' + 1000000)) : ℕ) : ℚ) <
      (((q - q') * (A - booked + 1) + (S - q' + 1000000) : ℕ) : ℚ) := by exact_mod_cast cd'.2
  have hcbq : (c : ℚ) ≤ booked := by exact_mod_cast hcb
  have hq'q : (q' : ℚ) < q := by exact_mod_cast hlt
  have hqS' : (q : ℚ) ≤ S := by exact_mod_cast hq
  have eA : ((A - booked : ℕ) : ℚ) = (A : ℚ) - booked := Nat.cast_sub (by omega)
  have eS : ((S - q' : ℕ) : ℚ) = (S : ℚ) - q' := Nat.cast_sub hqS
  have eq : ((q - q' : ℕ) : ℚ) = (q : ℚ) - q' := Nat.cast_sub hlt.le
  push_cast [eA, eS, eq] at ca qb2 qc2 fb1 cd2 ⊢
  have qN : (0 : ℚ) < (S : ℚ) + 1000000 := by positivity
  set N : ℚ := (S : ℚ) + 1000000 with hN
  set p : ℚ := ((A : ℚ) + 1) / N with hp
  have hpN : p * N = (A : ℚ) + 1 := by rw [hp]; field_simp
  have hN'' : (S : ℚ) - q' + 1000000 = N - q' := by rw [hN]; ring
  rw [hN''] at cd2
  have qN' : (0 : ℚ) < N - q' := by rw [hN]; linarith
  -- what the burned shares were worth, less what the market booked for them, is at least 0
  have he : (booked : ℚ) ≤ q' * p := by
    rw [← mul_le_mul_iff_of_pos_right qN]
    calc (booked : ℚ) * N ≤ q' * (A + 1) := fb1
      _ = q' * p * N := by rw [mul_assoc, hpN]
  have hMb : (A : ℚ) - booked + 1 = p * (N - q') + (q' * p - booked) := by rw [mul_sub, hpN]; ring
  have hqN : (q : ℚ) - q' ≤ N - q' := by rw [hN]; linarith
  -- the debt left is under what the position's shares were worth less the booking, plus a wei
  have h3 : (d' : ℚ) * (N - q') < ((q : ℚ) * p - booked + 1) * (N - q') := by
    have hl : ((q : ℚ) - q') * ((A : ℚ) - booked + 1) ≤
        (N - q') * (((q : ℚ) - q') * p + (q' * p - booked)) := by
      rw [hMb]
      linarith only [mul_le_mul_of_nonneg_right hqN (sub_nonneg.2 he)]
    linarith only [hl, cd2]
  have h4 : (d' : ℚ) < (q : ℚ) * p - booked + 1 := lt_of_mul_lt_mul_right h3 qN'.le
  have h5 : (q : ℚ) * p ≤ d := by
    rw [← mul_le_mul_iff_of_pos_right qN]
    calc (q : ℚ) * p * N = q * (A + 1) := by rw [mul_assoc, hpN]
      _ ≤ d * N := ca
  -- the payment clears all but under a wei and a share's price
  have h6 : (R : ℚ) < bought * p + p := by
    rw [← mul_lt_mul_iff_of_pos_right qN]
    calc (R : ℚ) * N < bought * (A + 1) + (A + 1) := qb2
      _ = (bought * p + p) * N := by rw [add_mul, mul_assoc, hpN]
  have h7 : (bought : ℚ) * p < c + 1 := by
    rw [← mul_lt_mul_iff_of_pos_right qN]
    calc (bought : ℚ) * p * N = bought * (A + 1) := by rw [mul_assoc, hpN]
      _ < c * N + N := qc2
      _ = (c + 1) * N := by ring
  linarith only [h4, h5, h6, h7, hcbq]

/-! ## Q2, Q3 -/

theorem lendersLoseOnlyRounding : LendersLoseOnlyRounding senzuLiquidation := by
  intro m q C D o P unit pen maxRepay U b C' D' ε hL
  obtain ⟨d, Dd, s, R, r, m', d', Dd', hU, hpen, hq, hd, hDd, rfl, hb, hl, hr, hm, hd', hDd', rfl, hC'⟩ := hL
  obtain ⟨-, -, b', hb', hs⟩ := liquidate_some hl
  rw [show senzuLiquidation.bearable = bearable from rfl, hb'] at hb
  obtain rfl := (Option.some.inj hb).symm
  obtain ⟨hmin, -, -⟩ := bearable_spec hb' hpen
  obtain ⟨hu, hsU, hRle, hv⟩ := seize_spec hs hmin
  obtain ⟨-, hd'le⟩ := debt_left hq hd (le_trans hRle (min_le_right _ _)) hr hm hd'
  have cD := (ceil_bounds hu (mulDivUp_spec hDd).2).1
  have cD' := (ceil_bounds hu (mulDivUp_spec hDd').2).2
  have hv' := seized_value hu hv
  have u0 : (0 : ℚ) < unit := by exact_mod_cast hu
  have U0 : (0 : ℚ) < U := by exact_mod_cast hU
  have w0 : (0 : ℚ) < WAD := by exact_mod_cast wad_pos
  have hP : (0 : ℚ) ≤ P := Nat.cast_nonneg P
  -- the debt in USD, before and after
  have e1 : (d : ℚ) * P / unit ≤ Dd := by
    rw [div_le_iff₀ u0]; exact_mod_cast cD
  have e2 : (Dd' : ℚ) < d' * P / unit + 1 := by
    rw [div_add_one u0.ne', lt_div_iff₀ u0]; exact_mod_cast cD'
  have e3 : (d' : ℚ) * P / unit ≤ (d - R + debtPrice m + 2) * P / unit :=
    div_le_div_of_nonneg_right (mul_le_mul_of_nonneg_right hd'le hP) u0.le
  -- the collateral after
  have e4 : ((U - s : ℕ) : ℚ) * C / U = C - s * C / U := by
    rw [Nat.cast_sub hsU]; field_simp
  rw [e4] at hC'
  have hk : (0 : ℚ) ≤ (b : ℚ) / WAD := by positivity
  have e5 : (b : ℚ) / WAD * Dd' ≤ (b : ℚ) / WAD * (Dd - R * P / unit + (debtPrice m + 2) * P / unit + 1) := by
    apply mul_le_mul_of_nonneg_left _ hk
    have : (d - R + debtPrice m + 2) * P / unit = (d : ℚ) * P / unit - R * P / unit + (debtPrice m + 2) * P / unit := by
      ring
    linarith
  have e6 : (R : ℚ) * P / unit * b / WAD = (b : ℚ) / WAD * (R * P / unit) := by ring
  unfold liquidationRounding
  push_cast
  nlinarith

theorem coveredStaysCovered : CoveredStaysCovered senzuLiquidation := by
  intro m q C D o P unit pen maxRepay U b C' D' ε hL hcov hdust
  have q2 := lendersLoseOnlyRounding m q C D o P unit pen maxRepay U b C' D' ε hL
  obtain ⟨-, -, -, -, -, -, -, -, -, hpen, -, -, -, -, hb, -⟩ := hL
  obtain ⟨hmin, -, hcap⟩ := bearable_spec hb hpen
  have hbD := hcap hcov
  have w0 : (0 : ℚ) < WAD := by exact_mod_cast wad_pos
  have hkD : (b : ℚ) / WAD * D ≤ C := by
    rw [div_mul_eq_mul_div, div_le_iff₀ w0]; exact_mod_cast hbD
  have hWM : WAD ≤ MIN_INCENTIVE := by unfold WAD MIN_INCENTIVE; norm_num
  rw [Nat.cast_sub hWM] at hdust
  have hkD' : (MIN_INCENTIVE : ℚ) / WAD * D' ≤ (b : ℚ) / WAD * D' := by
    apply mul_le_mul_of_nonneg_right _ (Nat.cast_nonneg _)
    exact div_le_div_of_nonneg_right (by exact_mod_cast hmin) w0.le
  have e : (MIN_INCENTIVE : ℚ) / WAD * D' - ((MIN_INCENTIVE : ℚ) - WAD) / WAD * D' = D' := by
    field_simp; ring
  have : (D' : ℚ) ≤ C' := by linarith
  exact_mod_cast this

/-! ## Q4: what doesn't revert -/

theorem mulDiv_ok {a b c : ℕ} (hc : 0 < c) (h : a * b / c < U256) : mulDiv a b c = some (a * b / c) := by
  simp [mulDiv, hc.ne', h]

theorem mulDivUp_ok {a b c : ℕ} (hc : 0 < c) (h : (a * b + c - 1) / c < U256) :
    mulDivUp a b c = some ((a * b + c - 1) / c) := by
  simp [mulDivUp, hc.ne', h]

theorem add256_ok {a b : ℕ} (h : a + b < U256) : add256 a b = some (a + b) := by simp [add256, h]
theorem sub_ok {a b : ℕ} (h : b ≤ a) : sub a b = some (a - b) := by simp [sub, h]
theorem toU128_ok {a : ℕ} (h : a < U128) : toU128 a = some a := by simp [toU128, h]
theorem require_ok {c : Prop} [Decidable c] (h : c) : require c = some () := by simp [require, h]

theorem u128_lt_u256 : U128 < U256 := by unfold U128 U256; norm_num

theorem ceil_pos {n d r : ℕ} (hd : 0 < d) (hr : r = (n + d - 1) / d) (hn : 0 < n) : 0 < r := by
  have := (ceil_bounds hd hr).1
  rcases Nat.eq_zero_or_pos r with rfl | h
  · simp at this; omega
  · exact h

/-- A ceiling of `n / d` is at most `n`. -/
theorem ceil_le_self {n d r : ℕ} (hd : 0 < d) (hr : r = (n + d - 1) / d) : r ≤ n := by
  have := (ceil_bounds hd hr).2
  by_contra h
  have : (n + 1) * d ≤ r * d := Nat.mul_le_mul_right _ (by omega)
  nlinarith

/-- A 128-bit total plus the virtual shares or assets fits in 256 bits. -/
theorem shares_virtual_lt {S : ℕ} (hS : S < U128) : S + VIRTUAL_SHARES < U256 :=
  lt_of_lt_of_le (Nat.add_lt_add_right hS _) (by unfold U128 U256 VIRTUAL_SHARES; norm_num)

theorem assets_virtual_lt {A : ℕ} (hA : A < U128) : A + VIRTUAL_ASSETS < U256 :=
  lt_of_lt_of_le (Nat.add_lt_add_right hA _) (by unfold U128 U256 VIRTUAL_ASSETS; norm_num)

/- `toShares` and `toAssets` as binds, so the lemmas below rewrite instead of unfolding (unfolding left the kernel a
`< 2^256` to decide on an open term, which took it gigabytes) -/
theorem toShares_eq {x A S : ℕ} (r : Rounding) : toShares x A S r =
    (add256 S VIRTUAL_SHARES).bind fun s => (add256 A VIRTUAL_ASSETS).bind fun t =>
      match r with | .up => mulDivUp x s t | .down => mulDiv x s t := rfl

theorem toAssets_eq {x A S : ℕ} (r : Rounding) : toAssets x A S r =
    (add256 A VIRTUAL_ASSETS).bind fun t => (add256 S VIRTUAL_SHARES).bind fun s =>
      match r with | .up => mulDivUp x t s | .down => mulDiv x t s := rfl

theorem repayBurns_eq {x a s : ℕ} : repayBurns x a s =
    (toShares x a s .down).bind fun b => (toAssets b a s .down).bind fun c => toShares c a s .up := rfl

/-- A payment `x` under the whole debt repays `x` and burns what `repayBurns` says. -/
theorem repayAmounts_partial {m : Market} {q x debt b : ℕ} (hq : q ≠ 0)
    (hd : toAssets q m.totalBorrowAssets m.totalBorrowShares .up = some debt) (hlt : ¬ debt ≤ x) (hx : x ≠ 0)
    (hb : repayBurns x m.totalBorrowAssets m.totalBorrowShares = some b) : repayAmounts m q x = some (x, b) := by
  simp only [repayAmounts, require_ok hq, hd, hlt, require_ok hx, hb, Option.bind_eq_bind, Option.bind_some,
    ↓reduceIte, Option.pure_def]

theorem toShares_down_ok {x A S : ℕ} (hS : S < U128) (hA : A < U128)
    (h : x * (S + VIRTUAL_SHARES) / (A + VIRTUAL_ASSETS) < U256) :
    toShares x A S .down = some (x * (S + VIRTUAL_SHARES) / (A + VIRTUAL_ASSETS)) := by
  rw [toShares_eq, add256_ok (shares_virtual_lt hS), Option.bind_some, add256_ok (assets_virtual_lt hA),
    Option.bind_some, mulDiv_ok (va_pos A) h]

theorem toShares_up_ok {x A S : ℕ} (hS : S < U128) (hA : A < U128)
    (h : (x * (S + VIRTUAL_SHARES) + (A + VIRTUAL_ASSETS) - 1) / (A + VIRTUAL_ASSETS) < U256) :
    toShares x A S .up = some ((x * (S + VIRTUAL_SHARES) + (A + VIRTUAL_ASSETS) - 1) / (A + VIRTUAL_ASSETS)) := by
  rw [toShares_eq, add256_ok (shares_virtual_lt hS), Option.bind_some, add256_ok (assets_virtual_lt hA),
    Option.bind_some, mulDivUp_ok (va_pos A) h]

theorem toAssets_down_ok {x A S : ℕ} (hS : S < U128) (hA : A < U128)
    (h : x * (A + VIRTUAL_ASSETS) / (S + VIRTUAL_SHARES) < U256) :
    toAssets x A S .down = some (x * (A + VIRTUAL_ASSETS) / (S + VIRTUAL_SHARES)) := by
  rw [toAssets_eq, add256_ok (assets_virtual_lt hA), Option.bind_some, add256_ok (shares_virtual_lt hS),
    Option.bind_some, mulDiv_ok (vs_pos S) h]

/-- A repayment of at most the market's shares never reverts while supply stays in its 128 bits. -/
theorem repay_ok {m : Market} {s p : ℕ} (hs : s ≤ m.totalBorrowShares) (hS : m.totalBorrowShares < U128)
    (hA : m.totalBorrowAssets ≤ m.totalSupplyAssets) (hsup : m.totalSupplyAssets + p < U128) :
    ∃ m', repay m s p = some m' := by
  have hu := u128_lt_u256
  obtain ⟨booked, hbk, hbA⟩ : ∃ b, repayBooks m s = some b ∧ b ≤ m.totalBorrowAssets := by
    unfold repayBooks
    split_ifs
    · exact ⟨_, rfl, le_refl _⟩
    · have hprod : s * (m.totalBorrowAssets + VIRTUAL_ASSETS) < U256 := by
        have h1 : s < U128 := by omega
        have h2 : m.totalBorrowAssets + VIRTUAL_ASSETS ≤ U128 := by unfold VIRTUAL_ASSETS; omega
        calc s * (m.totalBorrowAssets + VIRTUAL_ASSETS) < U128 * U128 :=
              Nat.mul_lt_mul_of_lt_of_le h1 h2 (by unfold U128; positivity)
          _ = U256 := by unfold U128 U256; norm_num
      refine ⟨_, toAssets_down_ok hS (by omega) (lt_of_le_of_lt (Nat.div_le_self _ _) hprod), ?_⟩
      exact booked_le hs (Nat.div_mul_le_self _ _)
  simp only [repay, reduceDebt, hbk, add256_ok (show m.totalSupplyAssets + p < U256 by omega),
    sub_ok (show booked ≤ m.totalSupplyAssets + p by omega), toU128_ok (show m.totalSupplyAssets + p - booked < U128 by omega),
    sub_ok hs, Option.bind_eq_bind, Option.bind_some, Option.pure_def]
  exact ⟨_, rfl⟩

theorem bearable_ok {C D pen : ℕ} (hC : C < 2 ^ 120) : ∃ b, bearable C D pen = some b := by
  unfold bearable
  split_ifs with hD
  · exact ⟨_, rfl⟩
  · have : C * WAD / D < U256 := by
      refine lt_of_le_of_lt (Nat.div_le_self _ _) ?_
      calc C * WAD < 2 ^ 120 * 2 ^ 136 := Nat.mul_lt_mul_of_lt_of_le hC (by unfold WAD; norm_num) (by positivity)
        _ = U256 := by unfold U256; norm_num
    rw [mulDiv_ok (Nat.pos_of_ne_zero hD) this]
    exact ⟨_, rfl⟩

/-- A seize within bounds never reverts, and repays something. -/
theorem seize_ok {U C R P unit b : ℕ} (hu : 0 < unit) (hP : 0 < P) (hC : 0 < C) (hR : 0 < R)
    (hRP : R * P / unit < 2 ^ 120) (hb : b ≤ 2 * WAD) (hU : U < 2 ^ 128) (hC' : C < 2 ^ 120)
    (hu' : unit < 2 ^ 120) : ∃ s R', seize U C R P unit b = some (s, R') ∧ 0 < R' ∧ R' ≤ R := by
  have hM : 0 < MIN_INCENTIVE := by unfold MIN_INCENTIVE; norm_num
  have hWM : WAD ≤ MIN_INCENTIVE := by unfold WAD MIN_INCENTIVE; norm_num
  have h256 : (2 : ℕ) ^ 241 < U256 := by unfold U256; norm_num
  set x := R * P / unit with hx
  set w := x * b / WAD with hw
  have hw2 : w ≤ 2 * x := by
    calc x * b / WAD ≤ x * (2 * WAD) / WAD := Nat.div_le_div_right (Nat.mul_le_mul_left _ hb)
      _ = 2 * x := by rw [show x * (2 * WAD) = 2 * x * WAD by ring, Nat.mul_div_cancel _ wad_pos]
  set sd := U * w / C with hsd
  set atMin := (C * WAD + MIN_INCENTIVE - 1) / MIN_INCENTIVE with hat
  have hatC : atMin ≤ C := by
    have := (ceil_bounds hM hat).2
    have : C * WAD ≤ C * MIN_INCENTIVE := Nat.mul_le_mul_left _ hWM
    by_contra h
    have : (C + 1) * MIN_INCENTIVE ≤ atMin * MIN_INCENTIVE := Nat.mul_le_mul_right _ (by omega)
    nlinarith
  have hat0 : 0 < atMin := ceil_pos hM hat (Nat.mul_pos hC wad_pos)
  set cov := (atMin * unit + P - 1) / P with hcov
  have hcovle : cov ≤ atMin * unit := ceil_le_self hP hcov
  have hcov0 : 0 < cov := ceil_pos hP hcov (Nat.mul_pos hat0 hu)
  have e1 : mulDiv R P unit = some x := mulDiv_ok hu (by omega)
  have e2 : mulDiv x b WAD = some w := mulDiv_ok wad_pos (by omega)
  have e3 : mulDiv U w C = some sd := by
    refine mulDiv_ok hC (lt_of_le_of_lt (Nat.div_le_self _ _) ?_)
    calc U * w < 2 ^ 128 * 2 ^ 121 := Nat.mul_lt_mul_of_lt_of_le hU (by omega) (by positivity)
      _ < U256 := by unfold U256; norm_num
  have e4 : mulDivUp C WAD MIN_INCENTIVE = some atMin := mulDivUp_ok hM (by omega)
  have e5 : mulDivUp atMin unit P = some cov := by
    refine mulDivUp_ok hP (lt_of_le_of_lt hcovle ?_)
    calc atMin * unit < 2 ^ 120 * 2 ^ 120 := Nat.mul_lt_mul_of_lt_of_le (by omega) hu'.le (by positivity)
      _ < U256 := by unfold U256; norm_num
  simp only [seize, e1, e2, e3, e4, e5, Option.bind_eq_bind, Option.bind_some, Option.pure_def]
  split_ifs with h1 h2
  · exact ⟨_, _, rfl, hcov0, h2.le⟩
  · exact ⟨_, _, rfl, hR, le_refl _⟩
  · exact ⟨_, _, rfl, hR, le_refl _⟩

theorem dustNeverBlocks : DustNeverBlocks senzuLiquidation := by
  intro m q C o P unit pen U d Dd hq0 hqS hS hprice hAsup hsupd hd hDd hC hP hu hpen hpenMax hC120 hD120 hU120 hu120
  set A := m.totalBorrowAssets with hA
  set S := m.totalBorrowShares with hS'
  have hN := vs_pos S
  have cd := ceil_bounds hN (toAssets_up hd)
  have hd0 : 0 < d := ceil_pos hN (toAssets_up hd) (Nat.mul_pos hq0 (va_pos A))
  -- the debt in USD bounds the repayment's
  have cD := (ceil_bounds hu (mulDivUp_spec hDd).2).1
  have hRP : d * P / unit < 2 ^ 120 := lt_of_le_of_lt (Nat.div_le_of_le_mul (le_of_le_of_eq cD (Nat.mul_comm _ _))) (by omega)
  obtain ⟨b, hb⟩ := bearable_ok (D := Dd + o) (pen := pen) hC120
  obtain ⟨hmin, hbpen, -⟩ := bearable_spec hb hpen
  have hb2 : b ≤ 2 * WAD := by unfold MAX_PENALTY at hpenMax; unfold WAD; omega
  obtain ⟨s, R, hs, hR0, hRd⟩ := seize_ok hu hP hC hd0 hRP hb2 (by unfold U128 at hU120; exact hU120) hC120 hu120
  have hl : senzuLiquidation.liquidate C (Dd + o) d P unit pen d U = some (s, R) := by
    simp only [Liquidation.liquidate, senzuLiquidation, require_ok hC.ne', require_ok hd0.ne', min_self,
      Option.bind_eq_bind, Option.bind_some, hb, hs]
  have hsup : m.totalSupplyAssets + R < U128 := by omega
  by_cases hdR : d ≤ R
  · obtain rfl : R = d := le_antisymm hRd hdR
    have hr : repayAmounts m q R = some (R, q) := by
      simp only [repayAmounts, require_ok hq0.ne', ← hA, ← hS', hd, Option.bind_eq_bind, Option.bind_some, le_refl,
        ↓reduceIte, Option.pure_def]
    obtain ⟨m', hm⟩ := repay_ok hqS hS hAsup hsup
    exact ⟨s, R, (R, q), m', hl, hr, hm⟩
  · -- repaying less than the debt burns at least one share, and fewer than the position's
    set sh := R * (S + VIRTUAL_SHARES) / (A + VIRTUAL_ASSETS) with hsh
    have hsh0 : 0 < sh := by
      refine (Nat.le_div_iff_mul_le (va_pos A)).mpr ?_
      have : 1 * (S + VIRTUAL_SHARES) ≤ R * (S + VIRTUAL_SHARES) := Nat.mul_le_mul_right _ hR0
      omega
    have hshq : sh < q := by
      refine (Nat.div_lt_iff_lt_mul (va_pos A)).mpr ?_
      have : (R + 1) * (S + VIRTUAL_SHARES) ≤ d * (S + VIRTUAL_SHARES) := Nat.mul_le_mul_right _ (by omega)
      nlinarith
    -- it clears the whole wei its shares were worth, and burns at most those shares
    have hshR : sh * (A + VIRTUAL_ASSETS) ≤ R * (S + VIRTUAL_SHARES) := Nat.div_mul_le_self _ _
    set c := sh * (A + VIRTUAL_ASSETS) / (S + VIRTUAL_SHARES) with hc
    have hcR : c ≤ R := Nat.div_le_of_le_mul (by rw [Nat.mul_comm (S + VIRTUAL_SHARES)]; exact hshR)
    have hcsh : c * (S + VIRTUAL_SHARES) ≤ sh * (A + VIRTUAL_ASSETS) := Nat.div_mul_le_self _ _
    set bn := (c * (S + VIRTUAL_SHARES) + (A + VIRTUAL_ASSETS) - 1) / (A + VIRTUAL_ASSETS) with hbn
    have hbnsh : bn ≤ sh := by
      refine Nat.le_of_lt_succ ((Nat.div_lt_iff_lt_mul (va_pos A)).mpr ?_)
      rw [Nat.succ_mul]
      have := va_pos A
      omega
    have hr : repayAmounts m q R = some (R, bn) := by
      refine repayAmounts_partial hq0.ne' hd hdR (by omega) ?_
      rw [repayBurns_eq, toShares_down_ok hS (by omega) (show sh < U256 by have := u128_lt_u256; omega),
        Option.bind_some, ← hsh, toAssets_down_ok hS (by omega) (show c < U256 by have := u128_lt_u256; omega),
        Option.bind_some, ← hc, toShares_up_ok hS (by omega) (show bn < U256 by have := u128_lt_u256; omega), ← hbn]
    obtain ⟨m', hm⟩ := repay_ok (show bn ≤ S by omega) hS hAsup hsup
    exact ⟨s, R, (R, bn), m', hl, hr, hm⟩

end Senzu.Proofs
