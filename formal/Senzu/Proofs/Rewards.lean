import Senzu.Proofs.Model

/-! # R1–R3: the reward ledger -/

namespace Senzu.Proofs

open Spec

theorem setAt_apply {α : Type} (f : ℕ → α) (k v k') : setAt f k v k' = if k' = k then v else f k' := rfl

theorem setAt₂_apply {α : Type} (f : ℕ → ℕ → α) (a l v a' l') :
    setAt f a (setAt (f a) l v) a' l' = if a' = a ∧ l' = l then v else f a' l' := by
  unfold setAt
  by_cases ha : a' = a <;> by_cases hl : l' = l <;> simp [ha, hl]

theorem q128_pos : 0 < Q128 := by unfold Q128; positivity

theorem rewardGrowth_some {L : Ledger} {lp u g : ℕ} (h : rewardGrowth L lp u = some g) : g = L.growth lp + u :=
  add256_some h

/-- What `owed` computed: the checkpoint's owed plus its units' growth since, rounded down. -/
theorem owed_some {cp : RewardCheckpoint} {b g o : ℕ} (h : owed cp b g = some o) :
    cp.growth ≤ g ∧ ∃ gained, gained * Q128 ≤ b * (g - cp.growth) ∧ o = cp.owed + gained := by
  simp only [owed, Option.bind_eq_bind, Option.bind_eq_some_iff] at h
  obtain ⟨dg, hdg, gained, hg, ho⟩ := h
  obtain ⟨hg1, rfl⟩ := sub_some hdg
  exact ⟨hg1, gained, (floor_bounds q128_pos (mulDiv_some hg)).1, add256_some ho⟩

theorem checkpoint_some {L L' : Ledger} {acc lp b : ℕ} (h : checkpoint L acc lp b = some L') :
    ∃ o, owed (L.checkpoints acc lp) b (L.growth lp) = some o ∧
      L' = { L with checkpoints := setAt L.checkpoints acc (setAt (L.checkpoints acc) lp ⟨L.growth lp, o⟩) } := by
  simp only [checkpoint, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
    Option.some.injEq] at h
  obtain ⟨o, ho, rfl⟩ := h
  exact ⟨o, ho, rfl⟩

/-- A booking either changes nothing, or adds what arrived per unit, rounded down, and what arrived for the
position. -/
theorem book_some {L L' : Ledger} {lp a liq : ℕ} (h : book L lp a liq = some L') :
    L' = L ∨ ∃ x, 0 < liq ∧ x * liq ≤ a * Q128 ∧
      L' = { L with
        growth := setAt L.growth lp (L.growth lp + x)
        positionRewards := setAt L.positionRewards lp (L.positionRewards lp + a) } := by
  unfold book at h
  split_ifs at h with h0
  · exact Or.inl (Option.some.inj h).symm
  rw [not_or] at h0
  simp only [Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq] at h
  obtain ⟨x, hx, g, hg, r, hr, rfl⟩ := h
  obtain rfl := add256_some hg
  obtain rfl := add256_some hr
  have hliq := Nat.pos_of_ne_zero h0.1
  exact Or.inr ⟨x, hliq, (floor_bounds hliq (mulDiv_some hx)).1, rfl⟩

theorem hold_some {L L' : Ledger} {x : ℕ} (h : hold L x = some L') : ∃ held, L' = { L with held } := by
  simp only [hold, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq] at h
  obtain ⟨held, -, rfl⟩ := h
  exact ⟨held, rfl⟩

theorem pay_some {L L' : Ledger} {acc lp amount : ℕ} (h : pay L acc lp = some (L', amount)) :
    amount ≤ L.positionRewards lp ∧
      ((L' = L ∧ amount = 0) ∨
        L' = { L with
          checkpoints := setAt L.checkpoints acc (setAt (L.checkpoints acc) lp
            { L.checkpoints acc lp with owed := (L.checkpoints acc lp).owed - amount })
          positionRewards := setAt L.positionRewards lp (L.positionRewards lp - amount)
          held := L.held - amount }) := by
  unfold pay at h
  dsimp only at h
  split_ifs at h with h0
  · simp only [Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨Nat.zero_le _, Or.inl ⟨rfl, rfl⟩⟩
  · simp only [Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    exact ⟨by omega, Or.inr rfl⟩

theorem ledgerRun_cons {r : Rewards} {L L₂ : Ledger} {act : LedgerAction} {rest : List LedgerAction} {paid : ℕ → ℕ}
    (h : r.run L (act :: rest) = some (L₂, paid)) :
    ∃ L₁ amount paid', r.step L act = some (L₁, amount) ∧ r.run L₁ rest = some (L₂, paid') ∧
      paid = fun l => if l = act.paysFrom then paid' l + amount else paid' l := by
  simp only [Rewards.run, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨⟨L₁, amount⟩, h₁, ⟨L₂', paid'⟩, h₂, rfl, rfl⟩ := h
  exact ⟨L₁, amount, paid', h₁, h₂, rfl⟩

/-! ## R1 -/

theorem add256_lt {a b r : ℕ} (h : add256 a b = some r) : r < U256 := by
  unfold add256 at h
  split_ifs at h with h1
  obtain rfl := Option.some.inj h
  exact h1

/-- A booking keeps every growth under 2^256 (its addition is checked). -/
theorem book_bounded {L L' : Ledger} {lp a liq : ℕ} (hb : ∀ l, L.growth l < U256)
    (h : book L lp a liq = some L') : ∀ l, L'.growth l < U256 := by
  unfold book at h
  split_ifs at h with h0
  · obtain rfl := Option.some.inj h
    exact hb
  simp only [Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq] at h
  obtain ⟨x, -, g, hg, r, -, rfl⟩ := h
  intro l
  simp only [setAt_apply]
  split_ifs
  · exact add256_lt hg
  · exact hb l

theorem gap_eq {g m : ℕ} (hm : m ≤ g) (hg : g < U256) : (g + U256 - m) % U256 = g - m := by
  rw [show g + U256 - m = g - m + U256 by omega, Nat.add_mod_right, Nat.mod_eq_of_lt (by omega)]

/-- A merged bookmark is at most the growth when both bookmarks are: its gap lies between theirs. -/
theorem mergeMark_le {h m held u g mark : ℕ} (hh : h ≤ g) (hm : m ≤ g) (hg : g < U256)
    (e : mergeMark h m held u g = some mark) : mark ≤ g := by
  unfold mergeMark at e
  rw [gap_eq hh hg, gap_eq hm hg] at e
  dsimp only at e
  simp only [Option.bind_eq_bind, Option.bind_eq_some_iff] at e
  obtain ⟨total, ht, e⟩ := e
  obtain rfl := add256_some ht
  split_ifs at e with hc
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨q, hq, rfl⟩ := e
    have : q ≤ g - m - (g - h) := by
      rw [mulDiv_some hq]
      exact Nat.div_le_of_le_mul (Nat.mul_le_mul_right _ (Nat.le_add_left u held))
    rw [gap_eq (by omega) hg]
    omega
  · simp only [Option.pure_def, Option.bind_eq_some_iff, Option.bind_some, Option.some.injEq] at e
    obtain ⟨q, -, rfl⟩ := e
    rw [gap_eq (by omega) hg]
    omega

/-- R1's invariant: every checkpoint is at most its position's booked growth, which is under 2^256. -/
def Sound (L : Ledger) : Prop := (∀ a lp, (L.checkpoints a lp).growth ≤ L.growth lp) ∧ ∀ lp, L.growth lp < U256

theorem sound_step {L L' : Ledger} {act : LedgerAction} {amount : ℕ} (hL : Sound L)
    (h : senzuRewards.step L act = some (L', amount)) : Sound L' := by
  cases act with
  | book lp a liq =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₁, h₁, rfl, -⟩ := h
    refine ⟨?_, book_bounded hL.2 h₁⟩
    rcases book_some h₁ with rfl | ⟨x, -, -, rfl⟩
    · exact hL.1
    · intro a' lp'
      have h1 := hL.1 a' lp'
      simp only [setAt_apply]
      split_ifs with he
      · subst he
        omega
      · exact h1
  | hold x =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₁, h₁, rfl, -⟩ := h
    obtain ⟨held, rfl⟩ := hold_some h₁
    exact hL
  | checkpoint acc lp b =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₁, h₁, rfl, -⟩ := h
    obtain ⟨o, -, rfl⟩ := checkpoint_some h₁
    refine ⟨fun a' lp' => ?_, hL.2⟩
    by_cases hc : a' = acc ∧ lp' = lp
    · obtain ⟨rfl, rfl⟩ := hc
      simp only [setAt₂_apply, and_self, ite_true, le_refl]
    · simp only [setAt₂_apply, hc, ite_false]
      exact hL.1 a' lp'
  | pay acc lp =>
    simp only [Rewards.step, senzuRewards] at h
    rcases (pay_some h).2 with ⟨rfl, -⟩ | rfl
    · exact hL
    · refine ⟨fun a' lp' => ?_, hL.2⟩
      by_cases hc : a' = acc ∧ lp' = lp
      · obtain ⟨rfl, rfl⟩ := hc
        simp only [setAt₂_apply, and_self, ite_true]
        exact hL.1 a' lp'
      · simp only [setAt₂_apply, hc, ite_false]
        exact hL.1 a' lp'
  | seize src dst lp srcBal held u =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₁, h₁, rfl, -⟩ := h
    unfold moveMarks at h₁
    by_cases h0 : src = dst ∨ u = 0
    · simp only [h0, ite_true, Option.some.injEq] at h₁
      obtain rfl := h₁
      exact hL
    simp only [h0, ite_false, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq] at h₁
    obtain ⟨mark, hmark, moved, -, dstOwed, -, rfl⟩ := h₁
    have hle := mergeMark_le (hL.1 dst lp) (hL.1 src lp) (hL.2 lp) hmark
    refine ⟨fun a' lp' => ?_, hL.2⟩
    by_cases hd : a' = dst ∧ lp' = lp
    · obtain ⟨rfl, rfl⟩ := hd
      simp only [setAt₂_apply, and_self, ite_true]
      exact hle
    · simp only [setAt₂_apply, hd, ite_false]
      by_cases hs : a' = src ∧ lp' = lp
      · obtain ⟨rfl, rfl⟩ := hs
        simp only [and_self, ite_true]
        exact hL.1 a' lp'
      · simp only [hs, ite_false]
        exact hL.1 a' lp'

theorem sound_run {L L' : Ledger} {paid : ℕ → ℕ} {acts : List LedgerAction} (hL : Sound L)
    (h : senzuRewards.run L acts = some (L', paid)) : Sound L' := by
  induction acts generalizing L paid with
  | nil =>
    simp only [Rewards.run, Option.pure_def, Option.some.injEq, Prod.mk.injEq] at h
    exact h.1 ▸ hL
  | cons act rest ih =>
    obtain ⟨L₁, amount, paid', h₁, h₂, -⟩ := ledgerRun_cons h
    exact ih (sound_step hL h₁) h₂

theorem nothingStuck : NothingStuck senzuRewards := by
  intro acts L paid h
  have hs := sound_run (L := Ledger.empty) ⟨fun _ _ => le_refl _, fun _ => by
    change 0 < U256
    unfold U256
    positivity⟩ h
  refine ⟨fun a lp u g hg => ?_, fun a lp => ?_⟩
  · rw [show senzuRewards.growth = rewardGrowth from rfl] at hg
    rw [rewardGrowth_some hg]
    exact le_trans (hs.1 a lp) (Nat.le_add_right _ _)
  · simp only [senzuRewards, pay]
    split <;> simp

/-! ## R2 -/

theorem arrivedFor_cons (lp : ℕ) (act : LedgerAction) (rest : List LedgerAction) :
    arrivedFor lp (act :: rest) = arrivedFor lp [act] + arrivedFor lp rest := by
  cases act <;> simp [arrivedFor]

theorem paid_step {L L₁ : Ledger} {act : LedgerAction} {amount lp : ℕ}
    (h : senzuRewards.step L act = some (L₁, amount)) :
    (if lp = act.paysFrom then amount else 0) + L₁.positionRewards lp ≤
      L.positionRewards lp + arrivedFor lp [act] := by
  cases act with
  | book l a liq =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₂, h₁, rfl, rfl⟩ := h
    simp only [arrivedFor, ite_self, Nat.zero_add, Nat.add_zero]
    rcases book_some h₁ with rfl | ⟨x, -, -, rfl⟩
    · exact Nat.le_add_right _ _
    · simp only [setAt_apply]
      by_cases hl : lp = l
      · subst hl
        simp only [ite_true]
        omega
      · simp only [hl, Ne.symm hl, ite_false]
        omega
  | hold x =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₂, h₁, rfl, rfl⟩ := h
    obtain ⟨held, rfl⟩ := hold_some h₁
    simp [arrivedFor]
  | checkpoint acc l b =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₂, h₁, rfl, rfl⟩ := h
    obtain ⟨o, -, rfl⟩ := checkpoint_some h₁
    simp [arrivedFor]
  | pay acc l =>
    simp only [Rewards.step, senzuRewards] at h
    obtain ⟨hle, h'⟩ := pay_some h
    change (if lp = l then amount else 0) + L₁.positionRewards lp ≤ L.positionRewards lp + 0
    rcases h' with ⟨rfl, rfl⟩ | rfl
    · simp
    · dsimp only
      rw [setAt_apply]
      by_cases hl : lp = l
      · subst hl
        simp only [ite_true]
        omega
      · simp only [hl, ite_false]
        omega
  | seize src dst l srcBal held u =>
    simp only [Rewards.step, senzuRewards, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
      Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨L₂, h₁, rfl, rfl⟩ := h
    have hp : L₂.positionRewards = L.positionRewards := by
      unfold moveMarks at h₁
      by_cases h0 : src = dst ∨ u = 0
      · simp only [h0, ite_true, Option.some.injEq] at h₁
        obtain rfl := h₁
        rfl
      · simp only [h0, ite_false, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
          Option.some.injEq] at h₁
        obtain ⟨mark, -, moved, -, dstOwed, -, rfl⟩ := h₁
        rfl
    simp [arrivedFor, hp]

theorem paid_run {L L' : Ledger} {paid : ℕ → ℕ} {acts : List LedgerAction} {lp : ℕ}
    (h : senzuRewards.run L acts = some (L', paid)) :
    paid lp + L'.positionRewards lp ≤ L.positionRewards lp + arrivedFor lp acts := by
  induction acts generalizing L paid with
  | nil =>
    simp only [Rewards.run, Option.pure_def, Option.some.injEq, Prod.mk.injEq] at h
    obtain ⟨rfl, rfl⟩ := h
    simp [arrivedFor]
  | cons act rest ih =>
    obtain ⟨L₁, amount, paid', h₁, h₂, rfl⟩ := ledgerRun_cons h
    have h1 := paid_step (lp := lp) h₁
    have h2 := ih h₂
    rw [arrivedFor_cons]
    dsimp only
    split_ifs at h1 ⊢ <;> omega

theorem paidAtMostArrived : PaidAtMostArrived senzuRewards := by
  intro acts L paid lp h
  have := paid_run (lp := lp) h
  simp only [Ledger.empty] at this
  omega

/-! ## R3 -/

theorem creditedAtMostItsShare : CreditedAtMostItsShare senzuRewards := by
  intro L acc lp b L₁ a liq L₂ L₃ h1 h2 h3
  simp only [senzuRewards] at h1 h2 h3
  obtain ⟨o1, -, rfl⟩ := checkpoint_some h1
  have hnn : (0 : ℚ) ≤ b * a / liq := by positivity
  rcases book_some h2 with rfl | ⟨x, hliq, hx, rfl⟩
  · -- nothing booked: the growth since the checkpoint is 0, so nothing is gained
    obtain ⟨o3, ho3, rfl⟩ := checkpoint_some h3
    simp only [setAt₂_apply, and_self, ite_true] at ho3 ⊢
    obtain ⟨-, gained, hga, rfl⟩ := owed_some ho3
    simp only [Nat.sub_self, Nat.mul_zero, Nat.le_zero, Nat.mul_eq_zero] at hga
    have hg0 : gained = 0 := by
      rcases hga with h | h
      · exact h
      · exact absurd h q128_pos.ne'
    subst hg0
    push_cast
    linarith only [hnn]
  · obtain ⟨o3, ho3, rfl⟩ := checkpoint_some h3
    simp only [setAt₂_apply, setAt_apply, and_self, ite_true] at ho3 ⊢
    obtain ⟨-, gained, hga, rfl⟩ := owed_some ho3
    rw [Nat.add_sub_cancel_left] at hga
    -- gained · Q128 ≤ b · x and x · liq ≤ a · Q128: gained ≤ b · a / liq
    have hQ : (0 : ℚ) < Q128 := by exact_mod_cast q128_pos
    have hL : (0 : ℚ) < liq := by exact_mod_cast hliq
    have k1 : (gained : ℚ) * Q128 ≤ b * x := by exact_mod_cast hga
    have k2 : (x : ℚ) * liq ≤ a * Q128 := by exact_mod_cast hx
    have hb : (0 : ℚ) ≤ b := Nat.cast_nonneg b
    have k3 := mul_le_mul_of_nonneg_right k1 hL.le
    have k4 := mul_le_mul_of_nonneg_left k2 hb
    have k5 : (gained : ℚ) * liq * Q128 ≤ b * a * Q128 := by linarith only [k3, k4]
    have k6 : (gained : ℚ) * liq ≤ b * a := le_of_mul_le_mul_right k5 hQ
    have k7 : (gained : ℚ) ≤ b * a / liq := by rw [le_div_iff₀ hL]; exact k6
    push_cast
    linarith only [k7]

end Senzu.Proofs
