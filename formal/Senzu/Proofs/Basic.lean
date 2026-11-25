import Mathlib.Tactic.Linarith
import Mathlib.Tactic.Positivity
import Mathlib.Tactic.FieldSimp
import Senzu.Spec

/-!
# Shared lemmas

What a successful `mulDiv`, `mulDivUp`, `toShares` and `toAssets` computed, and the floor and ceiling bounds the
proofs use.
-/

namespace Senzu.Proofs

theorem vs_pos (s : ℕ) : 0 < s + VIRTUAL_SHARES := by unfold VIRTUAL_SHARES; omega

theorem va_pos (a : ℕ) : 0 < a + VIRTUAL_ASSETS := by unfold VIRTUAL_ASSETS; omega

theorem lt_floor_succ_mul (n d : ℕ) (hd : 0 < d) : n < (n / d + 1) * d := by
  have := Nat.div_add_mod n d
  have := Nat.mod_lt n hd
  nlinarith

theorem le_ceil_mul (n d : ℕ) (hd : 0 < d) : n ≤ (n + d - 1) / d * d := by
  have h := lt_floor_succ_mul (n + d - 1) d hd
  rw [add_mul, one_mul] at h
  generalize (n + d - 1) / d * d = p at h
  omega

theorem ceil_mul_lt (n d : ℕ) (hd : 0 < d) : (n + d - 1) / d * d < n + d := by
  have h := Nat.div_mul_le_self (n + d - 1) d
  omega

theorem add256_some {a b r : ℕ} (h : add256 a b = some r) : r = a + b := by
  unfold add256 at h
  split_ifs at h
  exact (Option.some.inj h).symm

theorem mulDiv_some {a b c r : ℕ} (h : mulDiv a b c = some r) : r = a * b / c := by
  unfold mulDiv at h
  split_ifs at h
  exact (Option.some.inj h).symm

theorem mulDivUp_some {a b c r : ℕ} (h : mulDivUp a b c = some r) : r = (a * b + c - 1) / c := by
  unfold mulDivUp at h
  split_ifs at h
  exact (Option.some.inj h).symm

/-- A successful conversion is `mulDiv` or `mulDivUp` on the totals plus the virtual shares and assets. -/
theorem toShares_some {x a s r : ℕ} {rd : Rounding} (h : toShares x a s rd = some r) :
    (match rd with
      | .up => mulDivUp x (s + VIRTUAL_SHARES) (a + VIRTUAL_ASSETS)
      | .down => mulDiv x (s + VIRTUAL_SHARES) (a + VIRTUAL_ASSETS)) = some r := by
  unfold toShares at h
  cases h1 : add256 s VIRTUAL_SHARES with
  | none => simp only [h1, Option.bind_eq_bind, Option.bind_none, reduceCtorEq] at h
  | some n =>
    cases h2 : add256 a VIRTUAL_ASSETS with
    | none => simp only [h1, h2, Option.bind_eq_bind, Option.bind_some, Option.bind_none, reduceCtorEq] at h
    | some t =>
      simp only [h1, h2, Option.bind_eq_bind, Option.bind_some] at h
      obtain rfl := add256_some h1
      obtain rfl := add256_some h2
      cases rd <;> exact h

theorem toAssets_some {x a s r : ℕ} {rd : Rounding} (h : toAssets x a s rd = some r) :
    (match rd with
      | .up => mulDivUp x (a + VIRTUAL_ASSETS) (s + VIRTUAL_SHARES)
      | .down => mulDiv x (a + VIRTUAL_ASSETS) (s + VIRTUAL_SHARES)) = some r := by
  unfold toAssets at h
  cases h1 : add256 a VIRTUAL_ASSETS with
  | none => simp only [h1, Option.bind_eq_bind, Option.bind_none, reduceCtorEq] at h
  | some n =>
    cases h2 : add256 s VIRTUAL_SHARES with
    | none => simp only [h1, h2, Option.bind_eq_bind, Option.bind_some, Option.bind_none, reduceCtorEq] at h
    | some t =>
      simp only [h1, h2, Option.bind_eq_bind, Option.bind_some] at h
      obtain rfl := add256_some h1
      obtain rfl := add256_some h2
      cases rd <;> exact h

theorem toShares_down {x a s r : ℕ} (h : toShares x a s .down = some r) :
    r = x * (s + VIRTUAL_SHARES) / (a + VIRTUAL_ASSETS) :=
  mulDiv_some (toShares_some h)

theorem toShares_up {x a s r : ℕ} (h : toShares x a s .up = some r) :
    r = (x * (s + VIRTUAL_SHARES) + (a + VIRTUAL_ASSETS) - 1) / (a + VIRTUAL_ASSETS) :=
  mulDivUp_some (toShares_some h)

theorem toAssets_down {x a s r : ℕ} (h : toAssets x a s .down = some r) :
    r = x * (a + VIRTUAL_ASSETS) / (s + VIRTUAL_SHARES) :=
  mulDiv_some (toAssets_some h)

theorem toAssets_up {x a s r : ℕ} (h : toAssets x a s .up = some r) :
    r = (x * (a + VIRTUAL_ASSETS) + (s + VIRTUAL_SHARES) - 1) / (s + VIRTUAL_SHARES) :=
  mulDivUp_some (toAssets_some h)

/-- A floor: `r·d ≤ n < (r + 1)·d`. -/
theorem floor_bounds {n d r : ℕ} (hd : 0 < d) (hr : r = n / d) : r * d ≤ n ∧ n < r * d + d := by
  subst hr
  have := lt_floor_succ_mul n d hd
  exact ⟨Nat.div_mul_le_self n d, by linarith⟩

/-- A ceiling: `n ≤ r·d < n + d`. -/
theorem ceil_bounds {n d r : ℕ} (hd : 0 < d) (hr : r = (n + d - 1) / d) : n ≤ r * d ∧ r * d < n + d := by
  subst hr
  exact ⟨le_ceil_mul n d hd, ceil_mul_lt n d hd⟩

/-- What a payment `x` below the whole debt burns: shares `r` at most those `bought` it buys (rounded down), worth
the whole wei `c` those are worth (rounded down), rounded up. -/
theorem repayBurns_spec {x a s r : ℕ} (h : repayBurns x a s = some r) :
    ∃ bought c, bought * (a + VIRTUAL_ASSETS) ≤ x * (s + VIRTUAL_SHARES) ∧
      x * (s + VIRTUAL_SHARES) < bought * (a + VIRTUAL_ASSETS) + (a + VIRTUAL_ASSETS) ∧
      c * (s + VIRTUAL_SHARES) ≤ bought * (a + VIRTUAL_ASSETS) ∧
      bought * (a + VIRTUAL_ASSETS) < c * (s + VIRTUAL_SHARES) + (s + VIRTUAL_SHARES) ∧
      c * (s + VIRTUAL_SHARES) ≤ r * (a + VIRTUAL_ASSETS) ∧
      r * (a + VIRTUAL_ASSETS) < c * (s + VIRTUAL_SHARES) + (a + VIRTUAL_ASSETS) ∧ r ≤ bought := by
  simp only [repayBurns, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
  obtain ⟨bought, hb, c, hc, hr⟩ := h
  obtain ⟨b1, b2⟩ := floor_bounds (va_pos a) (toShares_down hb)
  obtain ⟨c1, c2⟩ := floor_bounds (vs_pos s) (toAssets_down hc)
  obtain ⟨r1, r2⟩ := ceil_bounds (va_pos a) (toShares_up hr)
  refine ⟨bought, c, b1, b2, c1, c2, r1, r2, ?_⟩
  exact Nat.le_of_lt_succ (Nat.lt_of_mul_lt_mul_right (a := a + VIRTUAL_ASSETS) (by rw [Nat.succ_mul]; omega))

end Senzu.Proofs
