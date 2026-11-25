import Senzu.Proofs.Health
import Senzu.Proofs.Range

/-!
# H2: the integer check over-values a corner by at most the √price's slack

The check's √price `r` sits within `δ` below the exact `s` (a floor root of a floored quotient is under 2 below the
exact root). Its amounts are at most the exact holdings at `r` (A1), and those are a point of Uniswap's curve. The
holdings after arbitrage (at `s`) are the curve's cheapest point; another point `t` costs
L·pY·(c − t)(s² − t·c)/(t·c) more, which `c − t ≤ δ` and `s² − t·c ≤ δ(2t + δ)` bound.
-/

namespace Senzu.Proofs

open Spec

/-! ## The curve's slack -/

/-- How much more the curve's point at `t` is worth than at `c`, with `pX = s²·pY`. -/
theorem curve_gap (a b L : ℝ) {t c s : ℝ} (ht : 0 < t) (hc : 0 < c) {p : ℝ × ℝ} (hp : p.1 = s * s * p.2) :
    curveValue a b L t p - curveValue a b L c p = L * p.2 * ((c - t) * (s * s - t * c)) / (t * c) := by
  unfold curveValue
  rw [hp]
  field_simp
  ring

/-- The curve's point at a √price `r` at most `δ` below `s`, brought into the range, is worth at most the slack more
than the holdings after arbitrage, for any `m` at most that point when the two differ. -/
theorem slack_bound {a b L r s δ m : ℝ} {p : ℝ × ℝ} (ha : 0 < a) (hab : a ≤ b) (hL : 0 ≤ L) (hp2 : 0 < p.2)
    (hp : p.1 = s * s * p.2) (hrs : r ≤ s) (hδ : s < r + δ) (hm0 : 0 < m)
    (hm : max a (min r b) < max a (min s b) → m ≤ max a (min r b)) :
    curveValue a b L (max a (min r b)) p ≤ curveValue a b L (max a (min s b)) p + sqrtSlack L p.2 δ m := by
  set t := max a (min r b) with ht
  set c := max a (min s b) with hc
  have ht0 : 0 < t := lt_of_lt_of_le ha (le_max_left _ _)
  have hc0 : 0 < c := lt_of_lt_of_le ha (le_max_left _ _)
  have hδ0 : 0 < δ := by linarith
  have slack0 : 0 ≤ sqrtSlack L p.2 δ m := by unfold sqrtSlack; positivity
  have htc : t ≤ c := max_le_max le_rfl (min_le_min_right _ hrs)
  rcases htc.lt_or_eq with hlt | heq
  · -- the check's point is below the cheapest: r < s, both inside the range
    have hmt := hm hlt
    have hcs : c = min s b := by
      rcases le_total (min s b) a with h | h
      · exfalso; rw [hc, max_eq_left h] at hlt; exact absurd hlt (not_lt.2 (le_max_left _ _))
      · rw [hc, max_eq_right h]
    have hrb : min r b = r := by
      rcases le_total r b with h | h
      · exact min_eq_left h
      · exfalso; rw [ht, min_eq_right h] at hlt
        have : c ≤ b := by rw [hcs]; exact min_le_right _ _
        exact absurd hlt (not_lt.2 (le_trans this (le_max_right _ _)))
    have hrt : r ≤ t := by rw [ht, hrb]; exact le_max_right _ _
    have hcs' : c ≤ s := by rw [hcs]; exact min_le_left _ _
    have d1 : 0 ≤ c - t := by linarith
    have d2 : c - t ≤ δ := by linarith
    have e1 : 0 ≤ s * s - t * c := by nlinarith
    have e2 : s * s - t * c ≤ δ * (2 * t + δ) := by nlinarith
    have prod : (c - t) * (s * s - t * c) ≤ δ ^ 2 * (2 * t + δ) := by
      calc (c - t) * (s * s - t * c) ≤ δ * (δ * (2 * t + δ)) := mul_le_mul d2 e2 e1 hδ0.le
        _ = δ ^ 2 * (2 * t + δ) := by ring
    have gap := curve_gap a b L ht0 hc0 hp
    have step : L * p.2 * ((c - t) * (s * s - t * c)) / (t * c) ≤ L * p.2 * (2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2) := by
      rw [div_le_iff₀ (by positivity)]
      have hLp : 0 ≤ L * p.2 := by positivity
      have key : (c - t) * (s * s - t * c) ≤ (2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2) * (t * c) := by
        have : (2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2) * (t * c) = δ ^ 2 * (2 * t + δ) * (c / t) := by
          field_simp
        rw [this]
        have : 1 ≤ c / t := by rw [le_div_iff₀ ht0]; linarith
        have q : δ ^ 2 * (2 * t + δ) ≤ δ ^ 2 * (2 * t + δ) * (c / t) := le_mul_of_one_le_right (by positivity) this
        linarith
      calc L * p.2 * ((c - t) * (s * s - t * c))
          ≤ L * p.2 * ((2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2) * (t * c)) := mul_le_mul_of_nonneg_left key hLp
        _ = L * p.2 * (2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2) * (t * c) := by ring
    have hm' : 2 * (δ ^ 2 / t) + δ ^ 3 / t ^ 2 ≤ 2 * (δ ^ 2 / m + δ ^ 3 / m ^ 2) := by
      have h1 : δ ^ 2 / t ≤ δ ^ 2 / m := div_le_div_of_nonneg_left (by positivity) hm0 hmt
      have h2 : δ ^ 3 / t ^ 2 ≤ δ ^ 3 / m ^ 2 :=
        div_le_div_of_nonneg_left (by positivity) (by positivity) (pow_le_pow_left₀ hm0.le hmt 2)
      have h3 : 0 ≤ δ ^ 3 / m ^ 2 := by positivity
      linarith
    unfold sqrtSlack
    have hLp : 0 ≤ L * p.2 := by positivity
    nlinarith [mul_le_mul_of_nonneg_left hm' hLp]
  · rw [heq]; linarith

/-! ## The check's √price -/

/-- A floor root of a floored quotient: at most the exact root, and less than 2 below it. -/
theorem root_bounds (n d k : ℕ) (hd : 0 < d) :
    (Nat.sqrt (n * 2 ^ k / d) : ℝ) ≤ Real.sqrt ((n : ℝ) * 2 ^ k / d) ∧
      Real.sqrt ((n : ℝ) * 2 ^ k / d) < Nat.sqrt (n * 2 ^ k / d) + 2 := by
  set x := n * 2 ^ k / d
  set r := Nat.sqrt x
  obtain ⟨f1, f2⟩ := floor_div_bounds (n * 2 ^ k) d hd
  push_cast at f1 f2
  have s1 : ((r : ℕ) : ℝ) ^ 2 ≤ x := by exact_mod_cast Nat.sqrt_le' x
  have s2 : (x : ℝ) < ((r : ℝ) + 1) ^ 2 := by exact_mod_cast Nat.lt_succ_sqrt' x
  have hX : 0 ≤ (n : ℝ) * 2 ^ k / d := by positivity
  constructor
  · rw [show (r : ℝ) = Real.sqrt ((r : ℝ) ^ 2) from (Real.sqrt_sq (by positivity)).symm]
    exact Real.sqrt_le_sqrt (by linarith)
  · rw [Real.sqrt_lt' (by positivity)]
    nlinarith

theorem mul256_some {a b r : ℕ} (h : mul256 a b = some r) : r = a * b := by
  unfold mul256 at h
  split_ifs at h
  exact (Option.some.inj h).symm

/-- What a successful `sqrtPriceX96Scaled` computed: the top √price for a ratio from 2^128, or a raw root `r`
(clamped) within `sqrtError` below the exact √(n/d). -/
theorem sqrtPrice_cases {q0 q1 sc0 sc1 s : ℕ} (hq1 : 0 < q1) (hsc0 : 0 < sc0)
    (h : sqrtPriceX96Scaled q0 q1 sc0 sc1 = some s) :
    (2 ^ 128 ≤ q0 * sc1 / (q1 * sc0) ∧ s = MAX_SQRT_PRICE) ∨
      ∃ r : ℕ, s = clampSqrt r ∧
        (r : ℝ) / Q96 ≤ Real.sqrt (((q0 * sc1 : ℕ) : ℝ) / (q1 * sc0 : ℕ)) ∧
        Real.sqrt (((q0 * sc1 : ℕ) : ℝ) / (q1 * sc0 : ℕ)) < (r : ℝ) / Q96 + sqrtError q0 q1 sc0 sc1 := by
  unfold sqrtPriceX96Scaled at h
  cases hn : mul256 q0 sc1 with
  | none => simp [hn] at h
  | some n =>
    cases hd : mul256 q1 sc0 with
    | none => simp [hn, hd] at h
    | some d =>
      simp only [hn, hd, Option.bind_eq_bind, Option.bind_some] at h
      obtain rfl := mul256_some hn
      obtain rfl := mul256_some hd
      have hd0 : 0 < q1 * sc0 := Nat.mul_pos hq1 hsc0
      have hQ : (0 : ℝ) < Q96 := by unfold Q96; positivity
      have hdR : (0 : ℝ) < ((q1 * sc0 : ℕ) : ℝ) := by exact_mod_cast hd0
      unfold sqrtOfRatio at h
      split_ifs at h with h1 h2
      · left
        rcases h1 with h1 | h1
        · omega
        · exact ⟨h1, (Option.some.inj h).symm⟩
      · -- the 96-bit root
        right
        obtain ⟨x, hx, rfl⟩ := Option.map_eq_some_iff.1 h
        refine ⟨Nat.sqrt x, rfl, ?_⟩
        rw [mulDiv_some hx]
        obtain ⟨b1, b2⟩ := root_bounds (q0 * sc1) (q1 * sc0) 192 hd0
        have e : Real.sqrt (((q0 * sc1 : ℕ) : ℝ) * 2 ^ 192 / ((q1 * sc0 : ℕ) : ℝ)) =
            Real.sqrt (((q0 * sc1 : ℕ) : ℝ) / ((q1 * sc0 : ℕ) : ℝ)) * Q96 := by
          rw [show ((q0 * sc1 : ℕ) : ℝ) * 2 ^ 192 / ((q1 * sc0 : ℕ) : ℝ) =
              ((q0 * sc1 : ℕ) : ℝ) / ((q1 * sc0 : ℕ) : ℝ) * ((Q96 : ℝ) ^ 2) by unfold Q96; push_cast; ring,
            Real.sqrt_mul (by positivity), Real.sqrt_sq hQ.le]
        rw [e] at b1 b2
        unfold sqrtError
        rw [if_pos h2]
        constructor
        · rw [div_le_iff₀ hQ]; exact b1
        · have : (2 : ℝ) ^ (-95 : ℤ) = 2 / Q96 := by unfold Q96; norm_num
          rw [this, ← add_div, lt_div_iff₀ hQ]; exact b2
      · -- the 64-bit root, shifted by 32
        right
        obtain ⟨x, hx, rfl⟩ := Option.map_eq_some_iff.1 h
        refine ⟨Nat.sqrt x * 2 ^ 32, rfl, ?_⟩
        rw [mulDiv_some hx]
        obtain ⟨b1, b2⟩ := root_bounds (q0 * sc1) (q1 * sc0) 128 hd0
        have e : Real.sqrt (((q0 * sc1 : ℕ) : ℝ) * 2 ^ 128 / ((q1 * sc0 : ℕ) : ℝ)) =
            Real.sqrt (((q0 * sc1 : ℕ) : ℝ) / ((q1 * sc0 : ℕ) : ℝ)) * 2 ^ 64 := by
          rw [show ((q0 * sc1 : ℕ) : ℝ) * 2 ^ 128 / ((q1 * sc0 : ℕ) : ℝ) =
              ((q0 * sc1 : ℕ) : ℝ) / ((q1 * sc0 : ℕ) : ℝ) * ((2 : ℝ) ^ 64) ^ 2 by ring,
            Real.sqrt_mul (by positivity), Real.sqrt_sq (by positivity)]
        rw [e] at b1 b2
        unfold sqrtError
        rw [if_neg h2]
        set R := Nat.sqrt (q0 * sc1 * 2 ^ 128 / (q1 * sc0))
        have hR : (((R * 2 ^ 32 : ℕ) : ℝ)) / Q96 = (R : ℝ) / 2 ^ 64 := by
          unfold Q96; push_cast; field_simp; ring
        rw [hR]
        constructor
        · rw [div_le_iff₀ (by positivity)]; exact b1
        · have : (2 : ℝ) ^ (-63 : ℤ) = 2 / 2 ^ 64 := by norm_num
          rw [this, ← add_div, lt_div_iff₀ (by positivity)]
          exact b2

end Senzu.Proofs
