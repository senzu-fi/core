import Senzu.Proofs.Basic

/-! # What a successful step of the model did -/

namespace Senzu.Proofs

theorem sub_some {a b r : ℕ} (h : sub a b = some r) : b ≤ a ∧ r = a - b := by
  unfold sub at h
  split_ifs at h with hb
  exact ⟨hb, (Option.some.inj h).symm⟩

theorem require_some {c : Prop} [Decidable c] {u : Unit} (h : require c = some u) : c := by
  unfold require at h
  split_ifs at h with hc
  exact hc

theorem add128_some {a b r : ℕ} (h : add128 a b = some r) : r = a + b := by
  unfold add128 at h
  split_ifs at h
  exact (Option.some.inj h).symm

theorem toU128_some {a r : ℕ} (h : toU128 a = some r) : r = a := by
  unfold toU128 at h
  split_ifs at h
  exact (Option.some.inj h).symm

theorem step_supply {l : Lending} {p p' : Pool} {x : ℕ} {out : ℤ}
    (h : l.step p (.supply x) = some (p', out)) :
    ∃ m, l.supplyShares x p.assets p.shares = some m ∧ p' = ⟨p.assets + x, p.shares + m⟩ ∧ out = -x := by
  simp only [Lending.step, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨m, hm, rfl, rfl⟩ := h
  exact ⟨m, hm, rfl, rfl⟩

theorem step_withdraw {l : Lending} {p p' : Pool} {s : ℕ} {out : ℤ}
    (h : l.step p (.withdraw s) = some (p', out)) :
    s ≤ p.shares ∧ ∃ a, l.withdrawAssets s p.assets p.shares = some a ∧ a ≤ p.assets ∧
      p' = ⟨p.assets - a, p.shares - s⟩ ∧ out = a := by
  simp only [Lending.step, Option.pure_def, Option.bind_eq_bind, Option.bind_none, Option.ite_none_left_eq_some,
    not_lt, Option.bind_eq_some_iff, Option.some.injEq, Prod.mk.injEq] at h
  obtain ⟨hs, a, ha, hle, rfl, rfl⟩ := h
  exact ⟨hs, a, ha, hle, rfl, rfl⟩

theorem step_accrue {l : Lending} {p p' : Pool} {i : ℕ} {out : ℤ}
    (h : l.step p (.accrue i) = some (p', out)) : p' = ⟨p.assets + i, p.shares⟩ ∧ out = 0 := by
  simp only [Lending.step, Option.pure_def, Option.some.injEq, Prod.mk.injEq] at h
  exact ⟨h.1.symm, h.2.symm⟩

theorem run_nil {l : Lending} {p p' : Pool} {out : ℤ} (h : l.run p [] = some (p', out)) :
    p' = p ∧ out = 0 := by
  simp only [Lending.run, Option.pure_def, Option.some.injEq, Prod.mk.injEq] at h
  exact ⟨h.1.symm, h.2.symm⟩

theorem run_cons {l : Lending} {p p₂ : Pool} {act : LendAction} {rest : List LendAction} {out : ℤ}
    (h : l.run p (act :: rest) = some (p₂, out)) :
    ∃ p₁ o₁ o₂, l.step p act = some (p₁, o₁) ∧ l.run p₁ rest = some (p₂, o₂) ∧ out = o₁ + o₂ := by
  simp only [Lending.run, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨⟨p₁, o₁⟩, h₁, ⟨p₂', o₂⟩, h₂, rfl, rfl⟩ := h
  exact ⟨p₁, o₁, o₂, h₁, h₂, rfl⟩

theorem repay_some {m m' : Market} {shares paid : ℕ} (h : repay m shares paid = some m') :
    ∃ booked, repayBooks m shares = some booked ∧ shares ≤ m.totalBorrowShares ∧
      booked ≤ m.totalSupplyAssets + paid ∧
      m' = ⟨m.totalSupplyAssets + paid - booked, m.totalBorrowAssets - booked, m.totalBorrowShares - shares⟩ := by
  simp only [repay, reduceDebt, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
    Option.some.injEq] at h
  obtain ⟨booked, hb, total, htot, s₁, hs₁, s₂, hs₂, m₁, ⟨bs, hbs, rfl⟩, rfl⟩ := h
  obtain rfl := add256_some htot
  obtain ⟨hle, rfl⟩ := sub_some hs₁
  obtain rfl := toU128_some hs₂
  obtain ⟨hs, rfl⟩ := sub_some hbs
  exact ⟨booked, hb, hs, hle, rfl⟩

theorem writeOffLoss_le (m : Market) (q debt : ℕ) : writeOffLoss m q debt ≤ m.totalBorrowAssets := by
  unfold writeOffLoss
  split_ifs <;> omega

theorem writeOffLoss_lt {m : Market} {q debt : ℕ} (hq : q < m.totalBorrowShares) :
    writeOffLoss m q debt = min debt m.totalBorrowAssets := by
  unfold writeOffLoss
  rw [ite_eq_right_of_eq_false _ _ (eq_false (Nat.ne_of_lt hq))]

theorem writeOff_some {m m' : Market} {q debt : ℕ} (h : writeOff m q = some (debt, m')) :
    toAssets q m.totalBorrowAssets m.totalBorrowShares .up = some debt ∧ q ≤ m.totalBorrowShares ∧
      m' = ⟨m.totalSupplyAssets - writeOffLoss m q debt, m.totalBorrowAssets - writeOffLoss m q debt,
        m.totalBorrowShares - q⟩ := by
  simp only [writeOff, reduceDebt, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff,
    Option.some.injEq, Prod.mk.injEq] at h
  obtain ⟨a, ha, m₁, ⟨bs, hbs, rfl⟩, rfl, rfl⟩ := h
  obtain ⟨hq, rfl⟩ := sub_some hbs
  exact ⟨ha, hq, rfl⟩

theorem addFee_some {m : Market} {fee ss fs sup : ℕ} (h : addFee m fee ss = some (fs, sup)) :
    sup = m.totalSupplyAssets + fee := by
  unfold addFee at h
  split_ifs at h with hf
  · simp only [Option.some.injEq, Prod.mk.injEq] at h
    omega
  · simp only [Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
      Prod.mk.injEq] at h
    obtain ⟨-, -, f1, hf1, s1, hs1, -, rfl⟩ := h
    obtain rfl := toU128_some hf1
    exact add128_some hs1

theorem addDebt_some {m m' : Market} {d fee ss q fs : ℕ} (h : addDebt m d fee ss = some (q, fs, m')) :
    m.totalBorrowAssets + d ≤ m.totalSupplyAssets ∧
      toShares (d + fee) m.totalBorrowAssets m.totalBorrowShares .up = some q ∧
      m' = ⟨m.totalSupplyAssets + fee, m.totalBorrowAssets + (d + fee), m.totalBorrowShares + q⟩ := by
  simp only [addDebt, Option.pure_def, Option.bind_eq_bind, Option.bind_eq_some_iff, Option.some.injEq,
    Prod.mk.injEq] at h
  obtain ⟨cash, hcash, u, hcashOk, debt, hdebt, ⟨fsh, sup⟩, hfee, sh, hsh, b, hb, b2, hb2, s3, hs3, s4, hs4,
    u₂, -, rfl, -, rfl⟩ := h
  obtain ⟨hle, rfl⟩ := sub_some hcash
  have hd := require_some hcashOk
  obtain rfl := add256_some hdebt
  obtain rfl := toU128_some hb
  obtain rfl := add128_some hb2
  obtain rfl := toU128_some hs3
  obtain rfl := add128_some hs4
  obtain rfl := addFee_some hfee
  exact ⟨by omega, hsh, rfl⟩

end Senzu.Proofs
