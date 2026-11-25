import Mathlib.Analysis.Convex.Segment
import Mathlib.Tactic
import Senzu.Spec

/-!
# H1, A2: the four-corner check covers the box, and a range position's value is concave

H1: along an edge of the box, a concave value less linear debts can't dip below both ends; two edges in each
direction reach every point from the corners.

A2: the holdings after arbitrage are the cheapest point of Uniswap's curve at those prices, so the value is the
least of linear functions, which is concave.
-/

namespace Senzu.Proofs

open Spec

/-- All positive prices. -/
abbrev Positive : Set (ℝ × ℝ) := Set.Ioi 0 ×ˢ Set.Ioi 0

/-! ## H1 -/

/-- Covered at both ends of a segment means covered along it. -/
theorem covered_on_segment {V : ℝ × ℝ → ℝ} (hV : ValueConcave V) {d : ℝ × ℝ} {others pen : ℝ}
    {u w z : ℝ × ℝ} (hu : u ∈ Positive) (hw : w ∈ Positive) (hz : z ∈ segment ℝ u w)
    (cu : pen * debtsAt d others u ≤ V u) (cw : pen * debtsAt d others w ≤ V w) :
    pen * debtsAt d others z ≤ V z := by
  obtain ⟨α, β, hα, hβ, hαβ, rfl⟩ := hz
  have hc := hV.2 hu hw hα hβ hαβ
  have hd : debtsAt d others (α • u + β • w) = α * debtsAt d others u + β * debtsAt d others w := by
    simp only [debtsAt, Prod.fst_add, Prod.snd_add, Prod.smul_fst, Prod.smul_snd, smul_eq_mul]
    linear_combination (-others) * hαβ
  rw [hd]
  simp only [smul_eq_mul] at hc
  nlinarith [mul_le_mul_of_nonneg_left cu hα, mul_le_mul_of_nonneg_left cw hβ]

theorem mk_mem_segment_left {x₁ x₂ x : ℝ} (y : ℝ) (hx : x ∈ Set.Icc x₁ x₂) :
    (x, y) ∈ segment ℝ (x₁, y) (x₂, y) := by
  rw [← Prod.image_mk_segment_left]
  exact ⟨x, by rw [segment_eq_uIcc]; exact Set.Icc_subset_uIcc hx, rfl⟩

theorem mk_mem_segment_right (x : ℝ) {y₁ y₂ y : ℝ} (hy : y ∈ Set.Icc y₁ y₂) :
    (x, y) ∈ segment ℝ (x, y₁) (x, y₂) := by
  rw [← Prod.image_mk_segment_right]
  exact ⟨y, by rw [segment_eq_uIcc]; exact Set.Icc_subset_uIcc hy, rfl⟩

theorem checkCoversBox : CheckCoversBox fourCorners := by
  intro V p σ d others pen hV hp1 hp2 hσ1 hσ2 _ _ hpen hcheck q hq others' hothers
  simp only [fourCorners, corners, List.mem_cons, List.mem_nil_iff, or_false, forall_eq_or_imp,
    forall_eq] at hcheck
  obtain ⟨c1, c2, c3, c4⟩ := hcheck
  obtain ⟨hqx, hqy⟩ := Set.mem_prod.1 hq
  have pos : ∀ x y : ℝ, 0 < x → 0 < y → (x, y) ∈ Positive := fun x y hx hy => ⟨hx, hy⟩
  have x1 : 0 < p.1 / σ.1 := by positivity
  have x2 : 0 < p.1 * σ.1 := by positivity
  have y1 : 0 < p.2 / σ.2 := by positivity
  have y2 : 0 < p.2 * σ.2 := by positivity
  have hq2 : 0 < q.2 := lt_of_lt_of_le y1 hqy.1
  have left := covered_on_segment hV (pos _ _ x1 y1) (pos _ _ x1 y2) (mk_mem_segment_right _ hqy) c1 c3
  have right := covered_on_segment hV (pos _ _ x2 y1) (pos _ _ x2 y2) (mk_mem_segment_right _ hqy) c2 c4
  have inside := covered_on_segment hV (pos _ _ x1 hq2) (pos _ _ x2 hq2) (mk_mem_segment_left _ hqx) left right
  calc pen * debtsAt d others' q ≤ pen * debtsAt d others q := by
        unfold debtsAt; exact mul_le_mul_of_nonneg_left (by linarith) hpen
    _ ≤ V q := inside

/-! ## A2 -/

/-- What the point of Uniswap's curve at √price `t` (inside `[a, b]`) is worth at prices `p`. -/
noncomputable def curveValue (a b L t : ℝ) (p : ℝ × ℝ) : ℝ :=
  L * (1 / t - 1 / b) * p.1 + L * (t - a) * p.2

/-- The holdings at √price `s` are the curve's point at `s` brought into the range. -/
theorem holdings_eq_clamp (a b L s : ℝ) (hab : a ≤ b) :
    holdings a b L s = (L * (1 / max a (min s b) - 1 / b), L * (max a (min s b) - a)) := by
  unfold holdings
  split_ifs with h1 h2
  · rw [min_eq_left (h1.trans hab), max_eq_left h1, sub_self, mul_zero]
  · rw [min_eq_left h2.le, max_eq_right (not_le.1 h1).le]
  · rw [min_eq_right (not_lt.1 h2), max_eq_right hab, sub_self, mul_zero]

theorem rangeValue_eq (a b L : ℝ) (hab : a ≤ b) (p : ℝ × ℝ) :
    rangeValue a b L p = curveValue a b L (max a (min (Real.sqrt (p.1 / p.2)) b)) p := by
  simp only [rangeValue, holdings_eq_clamp a b L _ hab, curveValue]

/-- No point of the curve is worth less than the holdings after arbitrage. -/
theorem arbitrage_cheapest {a b L t : ℝ} (ha : 0 < a) (hab : a ≤ b) (hL : 0 ≤ L) (ht : t ∈ Set.Icc a b)
    {p : ℝ × ℝ} (hp : p ∈ Positive) :
    rangeValue a b L p ≤ curveValue a b L t p := by
  obtain ⟨hp1, hp2⟩ := hp
  simp only [Set.mem_Ioi] at hp1 hp2
  rw [rangeValue_eq a b L hab]
  set s := Real.sqrt (p.1 / p.2) with hs
  have hs0 : 0 ≤ s := Real.sqrt_nonneg _
  have hss : s * s = p.1 / p.2 := Real.mul_self_sqrt (by positivity)
  have hp1' : p.1 = s * s * p.2 := by rw [hss]; field_simp
  set c := max a (min s b) with hc
  have hca : a ≤ c := le_max_left _ _
  have hcb : c ≤ b := max_le hab (min_le_right _ _)
  have ht0 : 0 < t := lt_of_lt_of_le ha ht.1
  have hc0 : 0 < c := lt_of_lt_of_le ha hca
  -- (t − c)(t·c − s²) ≥ 0 wherever the price is
  have key : 0 ≤ (t - c) * (t * c - s * s) := by
    rcases le_or_gt s a with h | h
    · have : c = a := by rw [hc, min_eq_left (h.trans hab), max_eq_left h]
      rw [this]
      nlinarith [ht.1, mul_le_mul h h hs0 ha.le, mul_le_mul_of_nonneg_right ht.1 ha.le]
    rcases lt_or_ge s b with h' | h'
    · have : c = s := by rw [hc, min_eq_left h'.le, max_eq_right h.le]
      rw [this]
      nlinarith [sq_nonneg (t - s)]
    · have : c = b := by rw [hc, min_eq_right h', max_eq_right hab]
      rw [this]
      have hb0 : 0 ≤ b := ha.le.trans hab
      have : t * b ≤ s * s := (mul_le_mul_of_nonneg_right ht.2 hb0).trans (mul_le_mul h' h' hb0 hs0)
      exact mul_nonneg_of_nonpos_of_nonpos (by linarith [ht.2]) (by linarith)
  have diff : curveValue a b L t p - curveValue a b L c p = L * p.2 * ((t - c) * (t * c - s * s)) / (t * c) := by
    unfold curveValue
    rw [hp1']
    field_simp
    ring
  have : 0 ≤ curveValue a b L t p - curveValue a b L c p := by
    rw [diff]; positivity
  linarith

theorem rangeValueConcave : RangeValueConcave rangeValue := by
  intro a b L ha hab hL
  refine ⟨(convex_Ioi 0).prod (convex_Ioi 0), ?_⟩
  intro x hx y hy α β hα hβ hαβ
  have hz : α • x + β • y ∈ Positive := ((convex_Ioi 0).prod (convex_Ioi 0)) hx hy hα hβ hαβ
  set c := max a (min (Real.sqrt ((α • x + β • y).1 / (α • x + β • y).2)) b)
  have hc : c ∈ Set.Icc a b := ⟨le_max_left _ _, max_le hab.le (min_le_right _ _)⟩
  have lin : curveValue a b L c (α • x + β • y) = α * curveValue a b L c x + β * curveValue a b L c y := by
    simp only [curveValue, Prod.fst_add, Prod.snd_add, Prod.smul_fst, Prod.smul_snd, smul_eq_mul]
    ring
  rw [smul_eq_mul, smul_eq_mul, rangeValue_eq a b L hab.le (α • x + β • y), lin]
  have hx' := arbitrage_cheapest ha hab.le hL hc hx
  have hy' := arbitrage_cheapest ha hab.le hL hc hy
  nlinarith [mul_le_mul_of_nonneg_left hx' hα, mul_le_mul_of_nonneg_left hy' hβ]

end Senzu.Proofs
