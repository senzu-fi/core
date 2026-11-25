import Senzu.Proofs.Basic

/-! # C1, C2: conversions round as labeled, by less than 1 -/

namespace Senzu.Proofs

open Spec

theorem floor_rat {n d r : ℕ} (hd : 0 < d) (hr : r = n / d) :
    (r : ℚ) ≤ (n : ℚ) / d ∧ (n : ℚ) / d < r + 1 := by
  obtain ⟨h1, h2⟩ := floor_bounds hd hr
  have hd' : (0 : ℚ) < d := by exact_mod_cast hd
  constructor
  · rw [le_div_iff₀ hd']
    exact_mod_cast h1
  · rw [div_lt_iff₀ hd', add_mul, one_mul]
    exact_mod_cast h2

theorem ceil_rat {n d r : ℕ} (hd : 0 < d) (hr : r = (n + d - 1) / d) :
    (n : ℚ) / d ≤ r ∧ (r : ℚ) < (n : ℚ) / d + 1 := by
  obtain ⟨h1, h2⟩ := ceil_bounds hd hr
  have hd' : (0 : ℚ) < d := by exact_mod_cast hd
  have h2' : (r : ℚ) * d < n + d := by exact_mod_cast h2
  constructor
  · rw [div_le_iff₀ hd']
    exact_mod_cast h1
  · rw [← sub_lt_iff_lt_add, lt_div_iff₀ hd']
    linarith

theorem exactShares_eq (x a s : ℕ) :
    exactShares x a s = ((x * (s + VIRTUAL_SHARES) : ℕ) : ℚ) / ((a + VIRTUAL_ASSETS : ℕ) : ℚ) := by
  rw [exactShares, Nat.cast_mul]

theorem exactAssets_eq (x a s : ℕ) :
    exactAssets x a s = ((x * (a + VIRTUAL_ASSETS) : ℕ) : ℚ) / ((s + VIRTUAL_SHARES : ℕ) : ℚ) := by
  rw [exactAssets, Nat.cast_mul]

theorem sharesRounding : SharesRounding toShares := by
  intro x a s r
  rw [exactShares_eq]
  exact ⟨fun h => floor_rat (va_pos a) (toShares_down h), fun h => ceil_rat (va_pos a) (toShares_up h)⟩

theorem assetsRounding : AssetsRounding toAssets := by
  intro x a s r
  rw [exactAssets_eq]
  exact ⟨fun h => floor_rat (vs_pos s) (toAssets_down h), fun h => ceil_rat (vs_pos s) (toAssets_up h)⟩

end Senzu.Proofs
