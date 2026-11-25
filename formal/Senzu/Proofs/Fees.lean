import Senzu.Fees
import Senzu.Proofs.Liquidation
import Senzu.Proofs.Rewards

/-! # FL1–FL3: the fee ledger -/

namespace Senzu.Proofs

open Spec FeeModel Finset

variable {A : Type} [Fintype A]

/-! ## Arithmetic -/

theorem add128_spec {a b r : ℕ} (h : add128 a b = some r) : r = a + b ∧ a + b < U128 := by
  by_cases h1 : a + b < U128
  · simp only [add128, h1, ite_true, Option.some.injEq] at h
    exact ⟨h.symm, h1⟩
  · simp [add128, h1] at h

theorem add256_spec {a b r : ℕ} (h : add256 a b = some r) : r = a + b ∧ a + b < U256 := by
  by_cases h1 : a + b < U256
  · simp only [add256, h1, ite_true, Option.some.injEq] at h
    exact ⟨h.symm, h1⟩
  · simp [add256, h1] at h

theorem sub_spec {a b r : ℕ} (h : sub a b = some r) : r = a - b ∧ b ≤ a := by
  by_cases h1 : b ≤ a
  · simp only [sub, h1, ite_true, Option.some.injEq] at h
    exact ⟨h.symm, h1⟩
  · simp [sub, h1] at h

theorem toU128_spec {a r : ℕ} (h : toU128 a = some r) : r = a ∧ a < U128 := by
  by_cases h1 : a < U128
  · simp only [toU128, h1, ite_true, Option.some.injEq] at h
    exact ⟨h.symm, h1⟩
  · simp [toU128, h1] at h

/-- Two sums that differ only at `x` and `y`, where `g` adds up to at most `f`. -/
theorem sum_le_of_pair {f g : A → ℕ} {x y : A} (hxy : x ≠ y) (h : ∀ a, a ≠ x → a ≠ y → g a = f a)
    (h2 : g x + g y ≤ f x + f y) : ∑ a, g a ≤ ∑ a, f a := by
  classical
  have hy : y ∈ (univ : Finset A).erase x := mem_erase.2 ⟨hxy.symm, mem_univ y⟩
  rw [← add_sum_erase univ g (mem_univ x), ← add_sum_erase univ f (mem_univ x), ← add_sum_erase _ g hy,
    ← add_sum_erase _ f hy]
  have : ∑ a ∈ ((univ : Finset A).erase x).erase y, g a = ∑ a ∈ ((univ : Finset A).erase x).erase y, f a :=
    sum_congr rfl fun a ha => h a (ne_of_mem_erase (mem_of_mem_erase ha)) (ne_of_mem_erase ha)
  omega

/-- Two sums that differ only at `x`, where `g x` is `f x` less `c`. -/
theorem sum_add_of_one {f g : A → ℕ} {x : A} {c : ℕ} (h : ∀ a, a ≠ x → g a = f a) (hx : g x + c = f x) :
    ∑ a, g a + c = ∑ a, f a := by
  classical
  rw [← add_sum_erase univ g (mem_univ x), ← add_sum_erase univ f (mem_univ x)]
  have : ∑ a ∈ (univ : Finset A).erase x, g a = ∑ a ∈ (univ : Finset A).erase x, f a :=
    sum_congr rfl fun a ha => h a (ne_of_mem_erase ha)
  omega

/-- A merge at the preview `P` of two bookmarks at most the booked growth `G` is at most `G` too, and the merged
units' gap to `G` is at most the two parts' gaps: the receiver is never credited more. -/
theorem mergeMark_fee {h m held u G P mark : ℕ} (hh : h ≤ G) (hm : m ≤ G) (hGP : G ≤ P) (hP : P < U256)
    (e : mergeMark h m held u P = some mark) :
    mark ≤ G ∧ (held + u) * (G - mark) ≤ held * (G - h) + u * (G - m) := by
  unfold mergeMark at e
  rw [gap_eq (by omega) hP, gap_eq (by omega) hP] at e
  dsimp only at e
  simp only [Option.bind_eq_bind, Option.bind_eq_some_iff] at e
  obtain ⟨total, ht, e⟩ := e
  obtain rfl := add256_some ht
  -- the merged gap to P, between the two gaps, and at most their units-weighted mix
  have key : ∀ gap, P - G ≤ gap → gap ≤ P → (held + u) * gap ≤ held * (P - h) + u * (P - m) →
      (P + U256 - gap) % U256 = mark →
      mark ≤ G ∧ (held + u) * (G - mark) ≤ held * (G - h) + u * (G - m) := by
    intro gap h1 h2 h3 h4
    rw [gap_eq h2 hP] at h4
    subst h4
    have hle : P - gap ≤ G := by omega
    refine ⟨hle, ?_⟩
    have hhP : h ≤ P := by omega
    have hmP : m ≤ P := by omega
    zify [hle, h2, hh, hm, hhP, hmP] at h3 ⊢
    nlinarith [h3]
  split_ifs at e with hc
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨q, hq, hmark⟩ := e
    obtain ⟨-, hq⟩ := mulDiv_spec hq
    have hmul : (held + u) * q ≤ u * (P - m - (P - h)) := by rw [hq]; exact Nat.mul_div_le _ _
    have hle : q ≤ P - m - (P - h) := by
      rw [hq]
      exact Nat.div_le_of_le_mul (Nat.mul_le_mul_right _ (Nat.le_add_left u held))
    have e1 : u * (P - m - (P - h)) + u * (P - h) = u * (P - m) := by rw [← Nat.mul_add]; congr 1; omega
    have e2 : (held + u) * (P - h + q) = held * (P - h) + u * (P - h) + (held + u) * q := by ring
    exact key _ (by omega) (by omega) (by omega) hmark
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨c, hc', hmark⟩ := e
    obtain ⟨ht, hc''⟩ := mulDivUp_spec hc'
    have hceil : u * (P - h - (P - m)) ≤ c * (held + u) := by rw [hc'']; exact le_ceil_mul _ _ ht
    have hle : c ≤ P - h - (P - m) := by
      rw [hc'', Nat.le_iff_lt_add_one, Nat.div_lt_iff_lt_mul ht]
      have : u * (P - h - (P - m)) ≤ (held + u) * (P - h - (P - m)) :=
        Nat.mul_le_mul_right _ (Nat.le_add_left u held)
      rw [Nat.add_mul, one_mul, Nat.mul_comm (P - h - (P - m))]
      omega
    have e1 : u * (P - h - (P - m)) + u * (P - m) = u * (P - h) := by rw [← Nat.mul_add]; congr 1; omega
    have e2 : (held + u) * (P - h - c) + (held + u) * c = (held + u) * (P - h) := by
      rw [← Nat.mul_add]; congr 1; omega
    have e3 : (held + u) * (P - h) = held * (P - h) + u * (P - h) := Nat.add_mul _ _ _
    have e4 : c * (held + u) = (held + u) * c := Nat.mul_comm _ _
    exact key _ (by omega) (by omega) (by omega) hmark

variable [DecidableEq A]

/-! ## The invariant -/

/-- FL1's invariant: every bookmark is at most the booked growth, which fits a `uint256`, the held fees fit a
`uint128`, and what every holder is owed or will be credited at the booked growth is at most what is held. -/
def FeeInv (s : FeeState A) : Prop :=
  s.growth < U256 ∧ (∀ a, s.mark a ≤ s.growth) ∧ s.held < U128 ∧
    ∑ a, (s.owed a * Q128 + s.units a * (s.growth - s.mark a)) ≤ s.held * Q128

omit [DecidableEq A] in
theorem feeInv_empty : FeeInv (FeeState.empty A) := by
  refine ⟨?_, fun _ => le_rfl, ?_, by simp [FeeState.empty]⟩
  · change (0 : ℕ) < U256
    unfold U256
    positivity
  · change (0 : ℕ) < U128
    unfold U128
    positivity

omit [DecidableEq A] in
theorem preview_spec {s : FeeState A} {P : ℕ} (hs : FeeInv s) (h : preview s = some P) :
    s.growth ≤ P ∧ P < U256 := by
  unfold preview at h
  split_ifs at h with ht
  · obtain rfl := Option.some.inj h
    exact ⟨le_rfl, hs.1⟩
  · simp only [Option.bind_eq_bind, Option.bind_eq_some_iff] at h
    obtain ⟨x, -, hx⟩ := h
    obtain ⟨rfl, hlt⟩ := add256_spec hx
    exact ⟨Nat.le_add_right _ _, hlt⟩

/-! ## Each step -/

omit [DecidableEq A] in
theorem poke_cases {s s' : FeeState A} (h : poke s = some s') :
    s' = s ∨ ∃ x, s' = { s with held := s.held + s.pending, growth := s.growth + x, pending := 0 } ∧
      x = s.pending * Q128 / s.total ∧ s.growth + x < U256 ∧ s.held + s.pending < U128 := by
  unfold poke at h
  split_ifs at h with hp
  · exact Or.inl (Option.some.inj h).symm
  · simp only [Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def, Option.some.injEq] at h
    obtain ⟨held, hh, x, hx, growth, hg, rfl⟩ := h
    obtain ⟨rfl, hh'⟩ := add128_spec hh
    obtain ⟨-, rfl⟩ := mulDiv_spec hx
    obtain ⟨rfl, hg'⟩ := add256_spec hg
    exact Or.inr ⟨_, rfl, rfl, hg', hh'⟩

omit [DecidableEq A] in
theorem poke_inv {s s' : FeeState A} (hs : FeeInv s) (h : poke s = some s') : FeeInv s' := by
  rcases poke_cases h with rfl | ⟨x, rfl, hx, hg, hh⟩
  · exact hs
  obtain ⟨-, hm, -, hsum⟩ := hs
  refine ⟨hg, fun a => le_trans (hm a) (Nat.le_add_right _ _), hh, ?_⟩
  dsimp only
  have hT : s.total * x ≤ s.pending * Q128 := hx ▸ Nat.mul_div_le _ _
  have e : ∑ a, (s.owed a * Q128 + s.units a * (s.growth + x - s.mark a)) =
      ∑ a, (s.owed a * Q128 + s.units a * (s.growth - s.mark a)) + s.total * x := by
    rw [FeeState.total, sum_mul, ← sum_add_distrib]
    refine sum_congr rfl fun a _ => ?_
    rw [show s.growth + x - s.mark a = (s.growth - s.mark a) + x by have := hm a; omega, Nat.mul_add]
    ring
  rw [e, Nat.add_mul]
  omega

omit [DecidableEq A] in
theorem poke_frame {s s' : FeeState A} (h : poke s = some s') :
    s'.units = s.units ∧ s'.mark = s.mark ∧ s'.owed = s.owed ∧ s'.held + s'.pending = s.held + s.pending := by
  rcases poke_cases h with rfl | ⟨x, rfl, -⟩
  · exact ⟨rfl, rfl, rfl, rfl⟩
  · exact ⟨rfl, rfl, rfl, by simp⟩

omit [Fintype A] in
theorem checkpoint_cases {s s' : FeeState A} {a : A} (h : FeeModel.checkpoint s a = some s') :
    ∃ o, s' = { s with owed := Function.update s.owed a o, mark := Function.update s.mark a s.growth } ∧
      ((s.units a = 0 ∧ o = s.owed a) ∨
        o = s.owed a + s.units a * ((s.growth + U256 - s.mark a) % U256) / Q128) := by
  unfold FeeModel.checkpoint at h
  by_cases hu : s.units a = 0
  · simp only [hu, ↓reduceIte, Option.bind_eq_bind, Option.pure_def, Option.some.injEq, Option.bind_some] at h
    exact ⟨s.owed a, h.symm, Or.inl ⟨hu, rfl⟩⟩
  · simp only [hu, ↓reduceIte, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq] at h
    obtain ⟨gained, hgn, o', ho', o, hto, rfl⟩ := h
    obtain ⟨-, rfl⟩ := mulDiv_spec hgn
    obtain ⟨rfl, -⟩ := add256_spec ho'
    obtain ⟨rfl, -⟩ := toU128_spec hto
    exact ⟨_, rfl, Or.inr rfl⟩

theorem checkpoint_inv {s s' : FeeState A} {a : A} (hs : FeeInv s) (h : FeeModel.checkpoint s a = some s') :
    FeeInv s' ∧ s'.mark a = s'.growth := by
  obtain ⟨o, rfl, ho⟩ := checkpoint_cases h
  obtain ⟨hg, hm, hh, hsum⟩ := hs
  refine ⟨⟨hg, fun b => ?_, hh, ?_⟩, by simp⟩
  · by_cases hb : b = a
    · subst hb
      simp
    · simp [Function.update_of_ne hb, hm b]
  · dsimp only
    refine le_trans (sum_le_sum fun b _ => ?_) hsum
    by_cases hb : b = a
    · subst hb
      simp only [Function.update_self, Nat.sub_self, Nat.mul_zero, Nat.add_zero]
      rcases ho with ⟨hu, rfl⟩ | rfl
      · rw [hu, Nat.zero_mul, Nat.add_zero]
      · rw [gap_eq (hm b) hg, Nat.add_mul]
        exact Nat.add_le_add_left (Nat.div_mul_le_self _ _) _
    · simp only [Function.update_of_ne hb, le_refl]

omit [Fintype A] in
theorem checkpoint_frame {s s' : FeeState A} {a : A} (h : FeeModel.checkpoint s a = some s') :
    s'.units = s.units ∧ s'.growth = s.growth ∧ s'.held = s.held ∧ s'.pending = s.pending := by
  obtain ⟨o, rfl, -⟩ := checkpoint_cases h
  exact ⟨rfl, rfl, rfl, rfl⟩

omit [Fintype A] in
theorem pay_cases {s s' : FeeState A} {a : A} {amount : ℕ} (h : FeeModel.pay s a = some (s', amount)) :
    amount = s.owed a ∧ s.owed a ≤ s.held ∧
      s' = { s with held := s.held - s.owed a, owed := Function.update s.owed a 0 } := by
  unfold FeeModel.pay at h
  simp only [Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨held, hh, rfl, rfl⟩ := h
  obtain ⟨rfl, hle⟩ := sub_spec hh
  exact ⟨rfl, hle, rfl⟩

theorem pay_inv {s s' : FeeState A} {a : A} {amount : ℕ} (hs : FeeInv s) (h : FeeModel.pay s a = some (s', amount)) :
    FeeInv s' := by
  obtain ⟨-, hle, rfl⟩ := pay_cases h
  obtain ⟨hg, hm, hh, hsum⟩ := hs
  refine ⟨hg, hm, by dsimp only; omega, ?_⟩
  dsimp only
  have e := sum_add_of_one (x := a) (c := s.owed a * Q128)
    (f := fun b => s.owed b * Q128 + s.units b * (s.growth - s.mark b))
    (g := fun b => Function.update s.owed a 0 b * Q128 + s.units b * (s.growth - s.mark b))
    (fun b hb => by simp only [Function.update_of_ne hb]) (by simp only [Function.update_self]; ring)
  have : s.owed a * Q128 ≤ s.held * Q128 := Nat.mul_le_mul_right _ hle
  rw [Nat.sub_mul]
  omega

theorem seize_cases {s s' : FeeState A} {src dst : A} {n : ℕ} (h : FeeModel.seize s src dst n = some s') :
    (src = dst ∨ n = 0) ∧ s' = s ∨ src ≠ dst ∧ n ≤ s.units src ∧ ∃ P mark moved, preview s = some P ∧
      mergeMark (s.mark dst) (s.mark src) (s.units dst) n P = some mark ∧
      (moved ≤ s.owed src ∧ s.owed src * n < (moved + 1) * s.units src) ∧
      s' = { s with
        mark := Function.update s.mark dst mark,
        owed := Function.update (Function.update s.owed src (s.owed src - moved)) dst (s.owed dst + moved),
        units := Function.update (Function.update s.units src (s.units src - n)) dst (s.units dst + n) } := by
  unfold FeeModel.seize at h
  split_ifs at h with h0 h1 h2
  · exact Or.inl ⟨h0, (Option.some.inj h).symm⟩
  all_goals
    push Not at h0
    simp only [Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def, Option.some.injEq,
      Option.bind_some] at h
  · obtain ⟨units, hu, P, hP, mark, hmk, dstOwed, hdo, rfl⟩ := h
    obtain ⟨rfl, hnu⟩ := sub_spec hu
    obtain ⟨rfl, -⟩ := add128_spec hdo
    refine Or.inr ⟨h0.1, hnu, P, mark, 0, hP, hmk, ⟨Nat.zero_le _, ?_⟩, rfl⟩
    rcases h1 with h1 | h1 <;> simp only [h1, Nat.zero_mul, Nat.zero_add, Nat.one_mul] <;> omega
  · obtain ⟨units, hu, P, hP, mark, hmk, dstOwed, hdo, rfl⟩ := h
    obtain ⟨rfl, hnu⟩ := sub_spec hu
    obtain ⟨rfl, -⟩ := add128_spec hdo
    refine Or.inr ⟨h0.1, hnu, P, mark, _, hP, hmk, ⟨le_rfl, ?_⟩, rfl⟩
    rw [show s.units src = n by omega, Nat.add_mul, Nat.one_mul]
    omega
  · obtain ⟨units, hu, P, hP, mark, hmk, moved, hmv, dstOwed, hdo, rfl⟩ := h
    obtain ⟨rfl, hnu⟩ := sub_spec hu
    obtain ⟨rfl, -⟩ := add128_spec hdo
    obtain ⟨-, rfl⟩ := mulDiv_spec hmv
    refine Or.inr ⟨h0.1, hnu, P, mark, _, hP, hmk, ⟨Nat.div_le_of_le_mul ?_, ?_⟩, rfl⟩
    · rw [Nat.mul_comm (s.units src)]
      exact Nat.mul_le_mul_left _ (by omega)
    · rw [Nat.mul_comm _ (s.units src)]
      exact Nat.lt_mul_div_succ _ (by omega)

theorem seize_inv {s s' : FeeState A} {src dst : A} {n : ℕ} (hs : FeeInv s) (h : FeeModel.seize s src dst n = some s') :
    FeeInv s' := by
  rcases seize_cases h with ⟨-, rfl⟩ | ⟨hne, hnu, P, mark, moved, hP, hmk, ⟨hmv, -⟩, rfl⟩
  · exact hs
  obtain ⟨hGP, hPU⟩ := preview_spec hs hP
  obtain ⟨hg, hm, hh, hsum⟩ := hs
  obtain ⟨hmark, hgap⟩ := mergeMark_fee (hm dst) (hm src) hGP hPU hmk
  refine ⟨hg, fun b => ?_, hh, ?_⟩
  · by_cases hb : b = dst
    · subst hb
      simpa using hmark
    · simp [Function.update_of_ne hb, hm b]
  dsimp only
  refine le_trans (sum_le_of_pair hne (f := fun b => s.owed b * Q128 + s.units b * (s.growth - s.mark b))
    (fun b hb1 hb2 => by simp only [Function.update_of_ne hb1, Function.update_of_ne hb2]) ?_) hsum
  simp only [Function.update_self, Function.update_of_ne hne]
  have e1 : (s.owed src - moved) * Q128 = s.owed src * Q128 - moved * Q128 := Nat.sub_mul _ _ _
  have e2 : (s.units src - n) * (s.growth - s.mark src) =
      s.units src * (s.growth - s.mark src) - n * (s.growth - s.mark src) := Nat.sub_mul _ _ _
  have e3 : (s.owed dst + moved) * Q128 = s.owed dst * Q128 + moved * Q128 := Nat.add_mul _ _ _
  have l1 : moved * Q128 ≤ s.owed src * Q128 := Nat.mul_le_mul_right _ hmv
  have l2 : n * (s.growth - s.mark src) ≤ s.units src * (s.growth - s.mark src) := Nat.mul_le_mul_right _ hnu
  rw [e1, e2, e3]
  omega

theorem seize_frame {s s' : FeeState A} {src dst : A} {n : ℕ} (h : FeeModel.seize s src dst n = some s') :
    s'.held = s.held ∧ s'.pending = s.pending := by
  rcases seize_cases h with ⟨-, rfl⟩ | ⟨-, -, P, mark, moved, -, -, -, rfl⟩
  · exact ⟨rfl, rfl⟩
  · exact ⟨rfl, rfl⟩

/-- Units change only right after their account's checkpoint, which leaves nothing to credit. -/
theorem setUnits_inv {s : FeeState A} {a : A} {v : ℕ} (hs : FeeInv s) (ha : s.mark a = s.growth) :
    FeeInv { s with units := Function.update s.units a v } := by
  obtain ⟨hg, hm, hh, hsum⟩ := hs
  refine ⟨hg, hm, hh, le_of_eq_of_le (sum_congr rfl fun b _ => ?_) hsum⟩
  by_cases hb : b = a
  · subst hb
    simp [ha]
  · simp [Function.update_of_ne hb]

/-! ## Any sequence of steps -/

theorem feeStep_inv {s s' : FeeState A} {act : FeeAction A} {amount : ℕ} (hs : FeeInv s)
    (h : (senzuFees A).step s act = some (s', amount)) : FeeInv s' := by
  cases act with
  | accrue x =>
    simp only [Fees.step] at h
    split_ifs at h
    obtain ⟨rfl, -⟩ := Prod.mk.inj (Option.some.inj h)
    exact hs
  | mint a n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, s₂, h₂, rfl, -⟩ := h
    obtain ⟨i₂, hm₂⟩ := checkpoint_inv (poke_inv hs h₁) h₂
    exact setUnits_inv i₂ hm₂
  | burn a n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, s₂, h₂, u, -, rfl, -⟩ := h
    obtain ⟨i₂, hm₂⟩ := checkpoint_inv (poke_inv hs h₁) h₂
    exact setUnits_inv i₂ hm₂
  | collect a =>
    by_cases hu : s.units a = 0
    · simp only [Fees.step, senzuFees, hu, ↓reduceIte, Option.bind_eq_bind, Option.bind_some] at h
      exact pay_inv hs h
    · simp only [Fees.step, senzuFees, hu, ↓reduceIte, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
      obtain ⟨s₀, h₀, s₁, h₁, h⟩ := h
      exact pay_inv (checkpoint_inv (poke_inv hs h₀) h₁).1 h
  | seize src dst n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, rfl, -⟩ := h
    exact seize_inv hs h₁

theorem feeStep_frame {s s' : FeeState A} {act : FeeAction A} {amount : ℕ}
    (h : (senzuFees A).step s act = some (s', amount)) :
    s'.held + s'.pending + amount = s.held + s.pending + earned [act] := by
  cases act with
  | accrue x =>
    simp only [Fees.step] at h
    split_ifs at h
    obtain ⟨rfl, rfl⟩ := Prod.mk.inj (Option.some.inj h)
    simp [earned]
    omega
  | mint a n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, s₂, h₂, rfl, rfl⟩ := h
    have f₁ := (poke_frame h₁).2.2.2
    have f₂ := checkpoint_frame h₂
    simp only [earned]
    omega
  | burn a n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, s₂, h₂, u, -, rfl, rfl⟩ := h
    have f₁ := (poke_frame h₁).2.2.2
    have f₂ := checkpoint_frame h₂
    simp only [earned]
    omega
  | collect a =>
    by_cases hu : s.units a = 0
    · simp only [Fees.step, senzuFees, hu, ↓reduceIte, Option.bind_eq_bind, Option.bind_some] at h
      obtain ⟨rfl, hle, rfl⟩ := pay_cases h
      simp only [earned]
      omega
    · simp only [Fees.step, senzuFees, hu, ↓reduceIte, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
      obtain ⟨s₀, h₀, s₁, h₁, h⟩ := h
      obtain ⟨rfl, hle, rfl⟩ := pay_cases h
      have f₂ := checkpoint_frame h₁
      have f₁ := (poke_frame h₀).2.2.2
      simp only [earned]
      omega
  | seize src dst n =>
    simp only [Fees.step, senzuFees, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.pure_def,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨s₁, h₁, rfl, rfl⟩ := h
    have := seize_frame h₁
    simp only [earned]
    omega

theorem feeRun_cons {f : Fees A} {s s₂ : FeeState A} {act : FeeAction A} {rest : List (FeeAction A)} {paid : ℕ}
    (h : f.run s (act :: rest) = some (s₂, paid)) :
    ∃ s₁ amount paid', f.step s act = some (s₁, amount) ∧ f.run s₁ rest = some (s₂, paid') ∧
      paid = amount + paid' := by
  simp only [Fees.run, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨⟨s₁, amount⟩, h₁, ⟨s₂', paid'⟩, h₂, rfl, rfl⟩ := h
  exact ⟨s₁, amount, paid', h₁, h₂, rfl⟩

omit [Fintype A] [DecidableEq A] in
theorem earned_cons (act : FeeAction A) (rest : List (FeeAction A)) :
    earned (act :: rest) = earned [act] + earned rest := by
  cases act <;> simp [earned]

theorem feeRun_inv {s s' : FeeState A} {acts : List (FeeAction A)} {paid : ℕ} (hs : FeeInv s)
    (h : (senzuFees A).run s acts = some (s', paid)) :
    FeeInv s' ∧ s'.held + s'.pending + paid = s.held + s.pending + earned acts := by
  induction acts generalizing s paid with
  | nil =>
    simp only [Fees.run, Option.pure_def, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨hs, by simp [earned]⟩
  | cons act rest ih =>
    obtain ⟨s₁, amount, paid', h₁, h₂, rfl⟩ := feeRun_cons h
    obtain ⟨i, e⟩ := ih (feeStep_inv hs h₁) h₂
    have := feeStep_frame h₁
    rw [earned_cons]
    exact ⟨i, by omega⟩

/-! ## FL1–FL3 -/

theorem q128_pos' : 0 < Q128 := by unfold Q128; positivity

theorem feesCollectable_run {acts : List (FeeAction A)} {s : FeeState A} {paid : ℕ}
    (h : (senzuFees A).run (FeeState.empty A) acts = some (s, paid)) :
    ∑ a, s.owed a ≤ s.held ∧
      ∀ a s₁ s₂, poke s = some s₁ → FeeModel.checkpoint s₁ a = some s₂ → s₂.owed a ≤ s₂.held := by
  have hs := (feeRun_inv feeInv_empty h).1
  -- what is owed is at most the sum the invariant bounds
  have owedLe : ∀ t : FeeState A, FeeInv t → (∑ a, t.owed a) * Q128 ≤ t.held * Q128 := fun t ht =>
    le_trans (by rw [sum_mul]; exact sum_le_sum fun a _ => Nat.le_add_right _ _) ht.2.2.2
  refine ⟨Nat.le_of_mul_le_mul_right (owedLe s hs) q128_pos', fun a s₁ s₂ h₁ h₂ => ?_⟩
  have i₂ := (checkpoint_inv (poke_inv hs h₁) h₂).1
  exact le_trans (single_le_sum (fun b _ => Nat.zero_le (s₂.owed b)) (mem_univ a))
    (Nat.le_of_mul_le_mul_right (owedLe s₂ i₂) q128_pos')

theorem feesPaidAtMostEarned_run {acts : List (FeeAction A)} {s : FeeState A} {paid : ℕ}
    (h : (senzuFees A).run (FeeState.empty A) acts = some (s, paid)) : paid ≤ earned acts := by
  have := (feeRun_inv feeInv_empty h).2
  simp only [FeeState.empty] at this
  omega

theorem feesCreditedAtMostItsShare_of {s s₁ s₂ s₃ : FeeState A} {a : A} (h₁ : FeeModel.checkpoint s a = some s₁)
    (h₂ : poke s₁ = some s₂) (h₃ : FeeModel.checkpoint s₂ a = some s₃) :
    (s₃.owed a : ℚ) ≤ s₁.owed a + s₁.units a * s₁.pending / s₁.total := by
  have hm₁ : s₁.mark a = s₁.growth := by
    obtain ⟨o, rfl, -⟩ := checkpoint_cases h₁
    simp
  have hRest : (0 : ℚ) ≤ s₁.units a * s₁.pending / s₁.total := by positivity
  obtain ⟨o, rfl, ho⟩ := checkpoint_cases h₃
  simp only [Function.update_self]
  rcases ho with ⟨-, rfl⟩ | rfl
  · rcases poke_cases h₂ with rfl | ⟨x, rfl, -⟩ <;> simpa using hRest
  rcases poke_cases h₂ with h₂ | ⟨x, rfl, hx, hg, -⟩
  · subst s₂
    rw [hm₁, show s₁.growth + U256 - s₁.growth = U256 by omega, Nat.mod_self, Nat.mul_zero, Nat.zero_div,
      Nat.add_zero]
    linarith
  · dsimp only at hg ⊢
    rw [hm₁, show s₁.growth + x + U256 - s₁.growth = x + U256 by omega, Nat.add_mod_right,
      Nat.mod_eq_of_lt (by omega)]
    push_cast
    have hq : (0 : ℚ) < Q128 := by exact_mod_cast q128_pos'
    have h1 : ((s₁.units a * x / Q128 : ℕ) : ℚ) ≤ (s₁.units a * x : ℕ) / Q128 := Nat.cast_div_le
    have h2 : ((x : ℕ) : ℚ) ≤ (s₁.pending * Q128 : ℕ) / s₁.total := hx ▸ Nat.cast_div_le
    have h3 : ((s₁.units a * x : ℕ) : ℚ) / Q128 ≤ s₁.units a * s₁.pending / s₁.total := by
      rw [div_le_iff₀ hq]
      push_cast at h2 ⊢
      calc (s₁.units a : ℚ) * x ≤ s₁.units a * (s₁.pending * Q128 / s₁.total) :=
            mul_le_mul_of_nonneg_left h2 (by positivity)
        _ = s₁.units a * s₁.pending / s₁.total * Q128 := by ring
    linarith

theorem add128_ok {a b : ℕ} (h : a + b < U128) : add128 a b = some (a + b) := by simp [add128, h]

omit [DecidableEq A] in
/-- Two accounts' parts of a sum over every account. -/
theorem pair_le_sum {f : A → ℕ} {x y : A} (hxy : x ≠ y) : f x + f y ≤ ∑ a, f a := by
  classical
  have := Finset.sum_le_sum_of_subset (f := f) (Finset.subset_univ {x, y})
  rwa [Finset.sum_pair hxy] at this

/-- A merge never reverts when both bookmarks are at most the growth it merges at and the units fit in 256 bits. -/
theorem mergeMark_ok {h m held u P : ℕ} (hh : h ≤ P) (hm : m ≤ P) (hP : P < U256) (hu : 0 < u)
    (ht : held + u < U256) : ∃ mark, mergeMark h m held u P = some mark := by
  unfold mergeMark
  rw [gap_eq hh hP, gap_eq hm hP, add256_ok ht]
  simp only [Option.bind_eq_bind, Option.bind_some, Option.pure_def]
  have hpos : 0 < held + u := by omega
  split_ifs with hc
  · rw [mulDiv_ok hpos (lt_of_le_of_lt (Nat.div_le_of_le_mul
      (Nat.mul_le_mul_right _ (Nat.le_add_left u held))) (by omega))]
    exact ⟨_, rfl⟩
  · have hle : (u * (P - h - (P - m)) + (held + u) - 1) / (held + u) ≤ P - h - (P - m) := by
      rw [Nat.le_iff_lt_add_one, Nat.div_lt_iff_lt_mul hpos]
      have : u * (P - h - (P - m)) ≤ (held + u) * (P - h - (P - m)) :=
        Nat.mul_le_mul_right _ (Nat.le_add_left u held)
      rw [Nat.add_mul, one_mul, Nat.mul_comm (P - h - (P - m))]
      omega
    rw [mulDivUp_ok hpos (by omega)]
    exact ⟨_, rfl⟩

/-- **S2**: a seize never reverts. The receiver's credited fees plus what moves to it are at most everything owed,
which the position holds (FL1), so they fit in 128 bits; the merge fits since both bookmarks are at most the
growth. Assumed: the units fit in 256 bits, and the DEX's unpaid fees preview without passing 2^256 (`_bookFees`
reverts on that same add first). -/
theorem seizeNeverReverts_inv {s : FeeState A} {src dst : A} {n P : ℕ} (hs : FeeInv s) (hT : s.total < U256)
    (hn : n ≤ s.units src) (hP : preview s = some P) : ∃ s', FeeModel.seize s src dst n = some s' := by
  unfold FeeModel.seize
  split_ifs with h0 h1 h2
  · exact ⟨_, rfl⟩
  all_goals
    push Not at h0
    obtain ⟨hGP, hPU⟩ := preview_spec hs hP
    obtain ⟨hg, hm, hh, hsum⟩ := hs
    have hunits : s.units src + s.units dst ≤ s.total := pair_le_sum h0.1
    have howed : s.owed src + s.owed dst ≤ s.held := by
      have := (pair_le_sum (f := fun b => s.owed b * Q128 + s.units b * (s.growth - s.mark b)) h0.1).trans hsum
      have h2 : (s.owed src + s.owed dst) * Q128 ≤ s.held * Q128 := by
        nlinarith [Nat.zero_le (s.units src * (s.growth - s.mark src)),
          Nat.zero_le (s.units dst * (s.growth - s.mark dst))]
      exact Nat.le_of_mul_le_mul_right h2 q128_pos'
    obtain ⟨mark, hmk⟩ := mergeMark_ok (held := s.units dst) (u := n) ((hm dst).trans hGP)
      ((hm src).trans hGP) hPU (Nat.pos_of_ne_zero h0.2) (by omega)
    simp only [Option.bind_eq_bind, sub_ok hn, hP, hmk, Option.bind_some]
  · rw [add128_ok (by omega)]
    exact ⟨_, rfl⟩
  · rw [add128_ok (by omega)]
    exact ⟨_, rfl⟩
  · have hle : s.owed src * n / s.units src ≤ s.owed src :=
      Nat.div_le_of_le_mul (by rw [Nat.mul_comm (s.units src)]; exact Nat.mul_le_mul_left _ (by omega))
    have hU : U128 < U256 := by unfold U128 U256; norm_num
    rw [mulDiv_ok (by omega) (by omega), Option.bind_some, add128_ok (by omega)]
    exact ⟨_, rfl⟩

/-- A merge at `P` loses the merged units under one growth unit each: their gap to `P` is at least the two parts'
gaps, less the units. -/
theorem mergeMark_lower {h m held u P mark : ℕ} (hh : h ≤ P) (hm : m ≤ P) (hP : P < U256)
    (e : mergeMark h m held u P = some mark) :
    held * (P - h) + u * (P - m) ≤ (held + u) * (P - mark) + (held + u) := by
  unfold mergeMark at e
  rw [gap_eq hh hP, gap_eq hm hP] at e
  simp only [Option.bind_eq_bind, Option.bind_eq_some_iff] at e
  obtain ⟨total, ht, e⟩ := e
  obtain rfl := add256_some ht
  split_ifs at e with hc
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨q, hq, hmark⟩ := e
    obtain ⟨hpos, hq⟩ := mulDiv_spec hq
    have hlt : u * (P - m - (P - h)) < (held + u) * (q + 1) := by rw [hq]; exact Nat.lt_mul_div_succ _ hpos
    have hgap : P - h + q ≤ P := by
      have : q ≤ P - m - (P - h) := by
        rw [hq]; exact Nat.div_le_of_le_mul (Nat.mul_le_mul_right _ (Nat.le_add_left u held))
      omega
    rw [gap_eq (by omega) hP] at hmark
    subst hmark
    rw [show P - (P - (P - h + q)) = P - h + q by omega]
    have e1 : u * (P - m - (P - h)) + u * (P - h) = u * (P - m) := by rw [← Nat.mul_add]; congr 1; omega
    have e2 : (held + u) * (P - h + q) + (held + u) = held * (P - h) + u * (P - h) + (held + u) * (q + 1) := by
      ring
    omega
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨c, hc', hmark⟩ := e
    obtain ⟨hpos, hc''⟩ := mulDivUp_spec hc'
    have hle : c ≤ P - h - (P - m) := by
      rw [hc'', Nat.le_iff_lt_add_one, Nat.div_lt_iff_lt_mul hpos]
      have : u * (P - h - (P - m)) ≤ (held + u) * (P - h - (P - m)) :=
        Nat.mul_le_mul_right _ (Nat.le_add_left u held)
      rw [Nat.add_mul, one_mul, Nat.mul_comm (P - h - (P - m))]
      omega
    have hup : c * (held + u) ≤ u * (P - h - (P - m)) + (held + u) - 1 := by
      rw [hc'']; exact Nat.div_mul_le_self _ _
    rw [gap_eq (by omega) hP] at hmark
    subst hmark
    rw [show P - (P - (P - h - c)) = P - h - c by omega]
    have e1 : u * (P - h - (P - m)) + u * (P - m) = u * (P - h) := by rw [← Nat.mul_add]; congr 1; omega
    have e2 : (held + u) * (P - h - c) + (held + u) * c = (held + u) * (P - h) := by
      rw [← Nat.mul_add]; congr 1; omega
    have e3 : (held + u) * (P - h) = held * (P - h) + u * (P - h) := Nat.add_mul _ _ _
    have e4 : c * (held + u) = (held + u) * c := Nat.mul_comm _ _
    omega

/-- **S1**: a seize moves the seized units' share of what the source could collect, credited fees included.
Nothing is created (the two claims after add up to at most before); the receiver gains its share of the source's
claim, less under one wei and one growth unit per unit it holds after (the roundings, against it); and seizing
every unit leaves the source nothing. Other accounts are untouched (`seize` updates `src` and `dst` only). -/
theorem seizeMovesItsShare_inv {s s' : FeeState A} {src dst : A} {n P : ℕ} (hs : FeeInv s)
    (hP : preview s = some P) (hne : src ≠ dst) (h : FeeModel.seize s src dst n = some s') :
    claimAt s' P src + claimAt s' P dst ≤ claimAt s P src + claimAt s P dst ∧
      (claimAt s P dst : ℚ) + n * claimAt s P src / s.units src ≤
        claimAt s' P dst + Q128 + (s.units dst + n) ∧
      (0 < n → n = s.units src → claimAt s' P src = 0) := by
  rcases seize_cases h with ⟨h0, h⟩ | ⟨-, hnu, P', mark, moved, hP', hmk, ⟨hle, hlo⟩, rfl⟩
  · subst s'
    obtain rfl : n = 0 := by tauto
    refine ⟨le_rfl, ?_, by omega⟩
    simp only [Nat.cast_zero, zero_mul, zero_div, add_zero]
    have : (0 : ℚ) ≤ Q128 + s.units dst := by positivity
    linarith
  obtain rfl : P = P' := Option.some.inj (hP.symm.trans hP')
  obtain ⟨hGP, hPU⟩ := preview_spec hs hP
  obtain ⟨-, hm, -, -⟩ := hs
  have hmd : s.mark dst ≤ P := (hm dst).trans hGP
  have hms : s.mark src ≤ P := (hm src).trans hGP
  obtain ⟨-, hup⟩ := mergeMark_fee hmd hms le_rfl hPU hmk
  have hlow := mergeMark_lower hmd hms hPU hmk
  simp only [claimAt, Function.update_self, Function.update_of_ne hne]
  refine ⟨?_, ?_, fun hn0 hn => ?_⟩
  · have e1 : (s.owed src - moved) * Q128 + moved * Q128 = s.owed src * Q128 := by
      rw [← Nat.add_mul, Nat.sub_add_cancel hle]
    have e2 : (s.units src - n) * (P - s.mark src) + n * (P - s.mark src) = s.units src * (P - s.mark src) := by
      rw [← Nat.add_mul, Nat.sub_add_cancel hnu]
    have e3 : (s.owed dst + moved) * Q128 = s.owed dst * Q128 + moved * Q128 := Nat.add_mul _ _ _
    omega
  · have hb : 0 < s.units src := by
      rcases Nat.eq_zero_or_pos (s.units src) with h0 | h0
      · rw [h0, Nat.mul_zero] at hlo; omega
      · exact h0
    have hbq : (0 : ℚ) < s.units src := by exact_mod_cast hb
    have hq : (0 : ℚ) ≤ Q128 := by positivity
    have hmoved : (s.owed src : ℚ) * n / s.units src ≤ moved + 1 := by
      rw [div_le_iff₀ hbq]; exact_mod_cast hlo.le
    have hlowq : ((s.units dst : ℕ) : ℚ) * ((P - s.mark dst : ℕ) : ℚ) + n * ((P - s.mark src : ℕ) : ℚ) ≤
        (s.units dst + n) * ((P - mark : ℕ) : ℚ) + (s.units dst + n) := by exact_mod_cast hlow
    have hshare : (n : ℚ) * ((s.owed src * Q128 + s.units src * (P - s.mark src) : ℕ) : ℚ) / s.units src =
        (s.owed src : ℚ) * n / s.units src * Q128 + n * ((P - s.mark src : ℕ) : ℚ) := by
      push_cast
      field_simp
    rw [hshare]
    push_cast
    nlinarith [mul_le_mul_of_nonneg_right hmoved hq]
  · subst hn
    rw [show s.owed src - moved = 0 by
      have : s.owed src < moved + 1 := Nat.lt_of_mul_lt_mul_right hlo
      omega]
    simp

/-! ## The statements, for Senzu's fee ledger -/

theorem feesCollectable : FeesCollectable (senzuFees A) :=
  fun _ _ _ h => feesCollectable_run h

theorem feesPaidAtMostEarned : FeesPaidAtMostEarned (senzuFees A) :=
  fun _ _ _ h => feesPaidAtMostEarned_run h

theorem feesCreditedAtMostItsShare : FeesCreditedAtMostItsShare (senzuFees A) :=
  fun _ _ _ _ _ h₁ h₂ h₃ => feesCreditedAtMostItsShare_of h₁ h₂ h₃

theorem seizeMovesItsShare : SeizeMovesItsShare (senzuFees A) :=
  fun _ _ _ h _ _ _ _ _ hne hP hs => seizeMovesItsShare_inv (feeRun_inv feeInv_empty h).1 hP hne hs

theorem seizeNeverReverts : SeizeNeverReverts (senzuFees A) := by
  intro _ _ _ h hT _ dst _ _ hn hP
  obtain ⟨s', hs'⟩ := seizeNeverReverts_inv (dst := dst) (feeRun_inv feeInv_empty h).1 hT hn hP
  simp [senzuFees, hs']

end Senzu.Proofs
