import Mathlib.Tactic.NormNum
import Senzu.Spec

/-!
# Mutants

Wrong wirings, each refuted by a statement in `Spec` with concrete numbers. A statement no mutant breaks can't
tell a bug from a fix, so every statement has at least one here.

Found while writing these: L1 (the round trip) accepts `withdrawRoundsUp`, since the supply's rounding absorbs
the extra unit. L4 and L5 reject it.
-/

namespace Senzu.Mutants

open Spec

/-- A supply mints shares rounded up. -/
def supplyRoundsUp : Lending := { senzu with supplyShares := fun x a s => toShares x a s .up }

/-- A withdrawal pays assets rounded up. -/
def withdrawRoundsUp : Lending := { senzu with withdrawAssets := fun x a s => toAssets x a s .up }

/-- A supply mints shares without the virtual shares and assets (the inflation-attack guard). -/
def supplyWithoutVirtual : Lending := { senzu with supplyShares := fun x a s => mulDiv x s a }

/-- A borrow mints borrow shares rounded down. -/
def borrowRoundsDown : Lending := { senzu with borrowShares := fun x a s => toShares x a s .down }

/-- Repaying part of a debt burns shares rounded up. -/
def repayRoundsUp : Lending := { senzu with repayShares := fun x a s => toShares x a s .up }

/-- The emptied-market attack: once a market's assets are gone, its exchange rate resets to the start, so a
deposit mints shares 1:1 although other shares are still outstanding. -/
def rateResetsWhenEmpty : Lending :=
  { senzu with supplyShares := fun x a s => if a = 0 then some x else toShares x a s .down }

/-- A write-off removes 1 wei more than the debt. -/
def writeOffPlusOne (m : Market) (q : Nat) : Option (Nat × Market) := do
  let debt ← toAssets q m.totalBorrowAssets m.totalBorrowShares .up
  let m ← reduceDebt m q (debt + 1)
  pure (debt + 1, { m with totalSupplyAssets := m.totalSupplyAssets - (debt + 1) })

/-- A write-off rounds the debt down. -/
def writeOffRoundsDown (m : Market) (q : Nat) : Option (Nat × Market) := do
  let debt ← toAssets q m.totalBorrowAssets m.totalBorrowShares .down
  let m ← reduceDebt m q debt
  pure (debt, { m with totalSupplyAssets := m.totalSupplyAssets - debt })

/-- A write-off of the last shares takes only their debt, as before 2026-11-20: the virtual shares' part stays. -/
def writeOffLeavesTheVirtualPart (m : Market) (q : Nat) : Option (Nat × Market) := do
  let debt ← toAssets q m.totalBorrowAssets m.totalBorrowShares .up
  let loss := min debt m.totalBorrowAssets
  let m ← reduceDebt m q loss
  pure (debt, { m with totalSupplyAssets := m.totalSupplyAssets - loss })

/-- A write-off lowers supply but forgets `totalBorrowAssets`. -/
def writeOffForgetsBorrows (m : Market) (q : Nat) : Option (Nat × Market) := do
  let debt ← toAssets q m.totalBorrowAssets m.totalBorrowShares .up
  let shares ← sub m.totalBorrowShares q
  pure (debt, ⟨m.totalSupplyAssets - debt, m.totalBorrowAssets, shares⟩)

/-- A repayment books what it was paid, rounded up, as before audit H-01. -/
def repayBooksThePayment (m : Market) (shares paid : Nat) : Option Market := reduceDebt m shares paid

/-- A repayment books the shares' worth but drops the rest of what it was paid. -/
def repayDropsTheRest (m : Market) (shares _paid : Nat) : Option Market := do
  let booked ← toAssets shares m.totalBorrowAssets m.totalBorrowShares .down
  reduceDebt m shares booked

/-- A booking that sets the growth to what arrived per unit instead of adding it. -/
def bookOverwrites (L : Ledger) (lp arrived liquidity : Nat) : Option Ledger :=
  if liquidity = 0 ∨ arrived = 0 then some L else do
    let x ← mulDiv arrived Q128 liquidity
    let rewards ← add256 (L.positionRewards lp) arrived
    pure { L with
      growth := setAt L.growth lp x
      positionRewards := setAt L.positionRewards lp rewards }

def rewardsBookOverwrites : Rewards := { senzuRewards with book := bookOverwrites }

/-- A payout capped by the rewards held, not by what its position was booked. -/
def payPastThePosition (L : Ledger) (account lp : Nat) : Option (Ledger × Nat) :=
  let cp := L.checkpoints account lp
  let amount := min cp.owed L.held
  some ({ L with
    checkpoints := setAt L.checkpoints account (setAt (L.checkpoints account) lp { cp with owed := cp.owed - amount })
    positionRewards := setAt L.positionRewards lp (L.positionRewards lp - amount)
    held := L.held - amount }, amount)

def rewardsPayPastThePosition : Rewards := { senzuRewards with pay := payPastThePosition }

/-- `owed` with the gain rounded up. -/
def owedUp (cp : RewardCheckpoint) (balance growth : Nat) : Option Nat := do
  let dg ← sub growth cp.growth
  let gained ← mulDivUp balance dg Q128
  add256 cp.owed gained

def checkpointUp (L : Ledger) (account lp balance : Nat) : Option Ledger := do
  let g := L.growth lp
  let o ← owedUp (L.checkpoints account lp) balance g
  pure { L with checkpoints := setAt L.checkpoints account (setAt (L.checkpoints account) lp ⟨g, o⟩) }

def rewardsGainUp : Rewards := { senzuRewards with checkpoint := checkpointUp }

/-- A repayment that books the last shares' worth rounded down, like every other's (the code before 2026-11-20's
review): the virtual shares' part of the debt stays with no one owing it. -/
def repayLeavesTheVirtualPart (m : Market) (shares paid : Nat) : Option Market := do
  let booked ← toAssets shares m.totalBorrowAssets m.totalBorrowShares .down
  let m' ← reduceDebt m shares booked
  pure { m' with totalSupplyAssets := ← add128 m'.totalSupplyAssets (paid - booked) }

def flip : Rounding → Rounding
  | .up => .down
  | .down => .up

/-- `toShares` with its roundings swapped. -/
def sharesSwapped (x a s : Nat) (r : Rounding) : Option Nat := toShares x a s (flip r)

/-- `toAssets` with its roundings swapped. -/
def assetsSwapped (x a s : Nat) (r : Rounding) : Option Nat := toAssets x a s (flip r)

/-! The market below has 10,000,000 assets and 1,000,000 shares: a share is worth about 5 units. -/

theorem c1_rejects_sharesSwapped : ¬ SharesRounding sharesSwapped := by
  intro h
  have := ((h 1 10000000 1000000 1).1 (by decide)).1
  norm_num [exactShares, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

theorem c2_rejects_assetsSwapped : ¬ AssetsRounding assetsSwapped := by
  intro h
  have := ((h 1 10000000 1000000 6).1 (by decide)).1
  norm_num [exactAssets, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Supplying 1 mints a whole share, worth 4 back. -/
theorem l1_rejects_supplyRoundsUp : ¬ SupplyWithdrawRoundTrip supplyRoundsUp := by
  intro h
  have := h 1 10000000 1000000 1 4 (by decide) (by decide)
  omega

/-- Supplying 9 mints nothing. -/
theorem l2_rejects_supplyWithoutVirtual : ¬ RoundTripLoss supplyWithoutVirtual := by
  intro h
  have := h 9 10000000 1000000 0 0 (by decide) (by decide)
  norm_num [sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

theorem l3_rejects_supplyRoundsUp : ¬ PriceNeverFalls supplyRoundsUp := by
  intro h
  have := h ⟨10000000, 1000000⟩ (.supply 1) ⟨10000001, 1000001⟩ (-1) (by decide)
  norm_num [sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

theorem l4_rejects_withdrawRoundsUp : ¬ PriceNeverFallsOverAnySequence withdrawRoundsUp := by
  intro h
  have := h ⟨10000000, 1000000⟩ [.withdraw 1] ⟨9999994, 999999⟩ 6 (by decide)
  norm_num [sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Withdrawing 1 share, worth 5.0000005, pays 6. -/
theorem l5_rejects_withdrawRoundsUp : ¬ NoFreeLunch withdrawRoundsUp := by
  intro h
  have := h ⟨10000000, 1000000⟩ [.withdraw 1] ⟨9999994, 999999⟩ 6 (by decide)
  norm_num [sharePrice, interestOf, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Supplying 1 mints a share worth 5.0000005. -/
theorem l5_rejects_supplyRoundsUp : ¬ NoFreeLunch supplyRoundsUp := by
  intro h
  have := h ⟨10000000, 1000000⟩ [.supply 1] ⟨10000001, 1000001⟩ (-1) (by decide)
  norm_num [sharePrice, interestOf, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Borrowing 1 mints no borrow shares: a free loan. -/
theorem b1_rejects_borrowRoundsDown : ¬ BorrowOwesAtLeastBorrowed borrowRoundsDown := by
  intro h
  have := h 1 10000000 1000000 0 0 (by decide) (by decide)
  omega

/-- Repaying 1 burns a share worth 5.0000005. -/
theorem b2_rejects_repayRoundsUp : ¬ RepayNeverOverCredits repayRoundsUp := by
  intro h
  have := h 1 10000000 1000000 1 (by decide)
  norm_num [sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- A market drained to 0 assets with 10^9 shares left: depositing 1,000,000 mints 1,000,000 shares, which
withdraw 998. -/
theorem l2_rejects_rateResetsWhenEmpty : ¬ RoundTripLoss rateResetsWhenEmpty := by
  intro h
  have := h 1000000 0 1000000000 1000000 998 (by decide) (by decide)
  norm_num [sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- A market with 10 supplied, 10 borrowed: writing off every borrow share leaves 0 supplied, 10 borrowed. -/
theorem m1_rejects_writeOffForgetsBorrows : ¬ CashNeverNegative writeOffForgetsBorrows := by
  intro h
  have := h ⟨10, 10, 10000000⟩ [.writeOff 10000000] ⟨0, 10, 0⟩ (by decide) (by decide)
  revert this
  decide

/-- Debt 2500.0005 rounds up to 2501, plus 1. -/
theorem w1_rejects_writeOffPlusOne : ¬ WriteOffCostsAtMostTheDebt writeOffPlusOne := by
  intro h
  have := h ⟨10000000, 5000000, 1000000⟩ 1000 2502 ⟨9997498, 4997498, 999000⟩ (by decide) (by decide)
  norm_num [exactAssets, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Borrowing 1 and being written off costs lenders 3, over the bound of about 2.000002. -/
theorem w2_rejects_writeOffPlusOne : ¬ BorrowThenWriteOff writeOffPlusOne := by
  intro h
  have := h ⟨1000, 1, 1⟩ 1 0 0 500001 0 ⟨1000, 2, 500002⟩ 3 ⟨997, 0, 1⟩ (by decide) (by decide) (by decide)
  norm_num [debtPrice, sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- Writing off debt 2500.0005 as 2500 leaves the 0.0005 on the other borrowers. -/
theorem w3_rejects_writeOffRoundsDown : ¬ WriteOffChargesNoOneElse writeOffRoundsDown := by
  intro h
  have := h ⟨10000000, 5000000, 1000000⟩ 1000 2500 ⟨9997500, 4997500, 999000⟩ (by decide) (by decide)
    (by decide)
  norm_num [debtPrice, sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- A one-share debt worth a millionth of a wei repays 1 and takes it off the market's debt: the debt per share
falls from 1/10^6 to 1/1999999. -/
theorem b3_rejects_repayBooksThePayment : ¬ RepayNeverLowersDebtPrice repayBooksThePayment := by
  intro h
  have := h ⟨1000000, 1, 1000000⟩ 1 1 (1, 1) ⟨1000000, 0, 999999⟩ (by decide) (by decide) (by decide) (by decide)
  norm_num [debtPrice, sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS] at this

/-- The same repayment books nothing and loses the wei it was paid. -/
theorem b4_rejects_repayDropsTheRest : ¬ RepayPaysLenders repayDropsTheRest := by
  intro h
  have := h ⟨1000000, 1, 1000000⟩ 1 1 (1, 1) ⟨1000000, 1, 999999⟩ (by decide) (by decide) (by decide)
  norm_num at this

/-- 2 arrives for a unit and a holder checkpoints; 1 more arrives and the growth drops under the checkpoint. -/
theorem r1_rejects_rewardsBookOverwrites : ¬ NothingStuck rewardsBookOverwrites := by
  intro h
  have := (h [.book 1 2 1, .checkpoint 1 1 1, .book 1 1 1] _ _ rfl).1 1 1 0 _ rfl
  exact absurd this (by decide)

/-- 1 arrives for a unit, a holder of 2 units is credited 2, and 2 are held: 2 paid, 1 arrived. -/
theorem r2_rejects_rewardsPayPastThePosition : ¬ PaidAtMostArrived rewardsPayPastThePosition := by
  intro h
  have := h [.book 1 1 1, .checkpoint 1 1 2, .hold 2, .pay 1 1] _ _ 1 rfl
  exact absurd this (by decide)

theorem not_le_a_third {o₁ o₃ : ℕ} (h₁ : o₁ = 0) (h₃ : o₃ = 1) :
    ¬ ((o₃ : ℚ) ≤ o₁ + ((1 : ℕ) : ℚ) * ((1 : ℕ) : ℚ) / ((3 : ℕ) : ℚ)) := by
  subst h₁ h₃
  norm_num

theorem eq_some_getD {o : Option Ledger} (h : o.isSome = true) : o = some (o.getD Ledger.empty) := by
  cases o <;> simp_all

/-! R3's case, step by step. -/

def gainUp₁ : Ledger := (checkpointUp Ledger.empty 1 1 1).getD Ledger.empty
def gainUp₂ : Ledger := (book gainUp₁ 1 1 3).getD Ledger.empty
def gainUp₃ : Ledger := (checkpointUp gainUp₂ 1 1 1).getD Ledger.empty

/-- One of a position's three units, when 1 arrives: rounding its third up credits it 1. -/
theorem r3_rejects_rewardsGainUp : ¬ CreditedAtMostItsShare rewardsGainUp := by
  intro h
  have := h Ledger.empty 1 1 1 gainUp₁ 1 3 gainUp₂ gainUp₃
    (eq_some_getD (by decide)) (eq_some_getD (by decide)) (eq_some_getD (by decide))
  exact not_le_a_third (by decide) (by decide) this

/-- Two wei of debt on a million shares: repaying them all pays 2 and books 1, leaving 1 wei that no one owes. -/
theorem b5_rejects_repayLeavesTheVirtualPart : ¬ LastRepayLeavesNoDebt repayLeavesTheVirtualPart := by
  intro h
  have := h ⟨1000, 2, 1000000⟩ 1000000 2 (2, 1000000) ⟨1001, 1, 0⟩ (by decide) (by decide) (by decide) (by decide)
  exact absurd this (by decide)

/-- 100 wei of debt on a million shares: the shares owe 51, the virtual shares hold the other 49, which stay. -/
theorem w4_rejects_writeOffLeavesTheVirtualPart : ¬ LastWriteOffLeavesNoDebt writeOffLeavesTheVirtualPart := by
  intro h
  have := h ⟨1000, 100, 1000000⟩ 51 ⟨949, 49, 0⟩ (by decide)
  exact absurd this (by decide)

/-! ## Liquidations -/

/-- Taking every unit caps the repayment at what the collateral covers, rounded down: a cent of collateral covers 0. -/
def coverableRoundsDown : Liquidation :=
  { senzuLiquidation with
    seize := fun units collateralUsd repay price unit penalty => do
      let repayUsd ← mulDiv repay price unit
      let withPenalty ← mulDiv repayUsd penalty WAD
      if collateralUsd ≤ withPenalty then do
        let atMin ← mulDiv collateralUsd WAD MIN_INCENTIVE
        let coverable ← mulDiv atMin unit price
        pure (units, if coverable < repay then coverable else repay)
      else do
        let seized ← mulDiv units withPenalty collateralUsd
        pure (seized, repay) }

/-- A liquidation takes the units rounded up. -/
def seizeRoundsUp : Liquidation :=
  { senzuLiquidation with
    seize := fun units collateralUsd repay price unit penalty => do
      let repayUsd ← mulDiv repay price unit
      let withPenalty ← mulDiv repayUsd penalty WAD
      if collateralUsd ≤ withPenalty then do
        let atMin ← mulDivUp collateralUsd WAD MIN_INCENTIVE
        let coverable ← mulDivUp atMin unit price
        pure (units, if coverable < repay then coverable else repay)
      else do
        let seized ← mulDivUp units withPenalty collateralUsd
        pure (seized, repay) }

/-- The penalty is never shrunk to what the position can bear. -/
def bearableUncapped : Liquidation := { senzuLiquidation with bearable := fun _ _ pen => some pen }

/-- One unit worth 10^-18 USD against a debt of 1 wei at 1 USD: the liquidator takes the unit and repays 0. -/
theorem q1_rejects_coverableRoundsDown : ¬ LiquidatorTakesNoMore coverableRoundsDown := by
  intro h
  have := (h 1 (10 ^ 18) 1 (10 ^ 18) 1 MIN_INCENTIVE 1 1 1 0 MIN_INCENTIVE (le_refl _) (by decide) (by decide)).2.2.2
  norm_num at this

/-- The same: the only liquidation repays 0, which the market refuses. -/
theorem q4_rejects_coverableRoundsDown : ¬ DustNeverBlocks coverableRoundsDown := by
  intro h
  obtain ⟨s, R, r, m', hl, hr, -⟩ := h ⟨1, 1, 1000000⟩ 1000000 1 0 (10 ^ 18) 1 MIN_INCENTIVE 1 1 (10 ^ 18)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
    (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide) (by decide)
  rw [show coverableRoundsDown.liquidate 1 (10 ^ 18 + 0) 1 (10 ^ 18) 1 MIN_INCENTIVE 1 1 = some (1, 0) by decide] at hl
  simp only [Option.some.injEq, Prod.mk.injEq] at hl
  obtain ⟨-, rfl⟩ := hl
  rw [show repayAmounts ⟨1, 1, 1000000⟩ 1000000 0 = none by decide] at hr
  cases hr

/-- A $10 debt, its shares worth 10^-6 wei each, repaid against 100 units worth $70: taking 15 units instead of
14.57 costs lenders $0.29 over the rounding allowed. -/
theorem q2_rejects_seizeRoundsUp : ¬ LendersLoseOnlyRounding seizeRoundsUp := by
  intro h
  have := h ⟨10 ^ 7, 9999999, 9999999000000⟩ 9999999000000 (70 * 10 ^ 18) (9999999 * 10 ^ 12) 0 (10 ^ 18)
    (10 ^ 6) MIN_INCENTIVE 9999999 100 MIN_INCENTIVE 58800000000000000000 0 (7 * 10 ^ 17)
    ⟨9999999, 9999999 * 10 ^ 12, 15, 9999999, (9999999, 9999999000000), ⟨10 ^ 7, 0, 0⟩, 0, 0,
      by decide, by decide, by decide, by decide, by decide, rfl, by decide, by decide, by decide, by decide,
      by decide, by decide, rfl, by norm_num⟩
  norm_num [liquidationRounding, debtPrice, sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS, MIN_INCENTIVE, WAD] at this

/-- A position with collateral 1.1 × its $10 debt repays $8 at the full 1.25 penalty: $1 of collateral is left
against $2 of debt. -/
theorem q3_rejects_bearableUncapped : ¬ CoveredStaysCovered bearableUncapped := by
  intro h
  have := h ⟨10 ^ 7, 9999999, 9999999000000⟩ 9999999000000 10999998900000000000 (9999999 * 10 ^ 12) 0 (10 ^ 18)
    (10 ^ 6) MAX_PENALTY 8000000 1100 MAX_PENALTY 999999900000000000 (1999999 * 10 ^ 12) (9999999 * 10 ^ 9)
    ⟨9999999, 9999999 * 10 ^ 12, 1000, 8000000, (8000000, 8000000000000), ⟨10 ^ 7, 1999999, 1999999000000⟩, 1999999,
      1999999 * 10 ^ 12, by decide, by decide, by decide, by decide, by decide, rfl, by decide, by decide, by decide,
      by decide, by decide, by decide, rfl, by norm_num⟩
    (by decide) (by norm_num [liquidationRounding, debtPrice, sharePrice, VIRTUAL_SHARES, VIRTUAL_ASSETS,
      MIN_INCENTIVE, MAX_PENALTY, WAD])
  exact absurd this (by decide)

/-! ## The liquidation fee -/

/-- The fee on everything the liquidator seized, not on its gain. -/
def feeOnSeized : FeeRule := fun C D d price unit U seized repaid feeWad other =>
  if feeWad = 0 ∨ seized = 0 then some 0 else do
    let atFloor ← mulDiv C WAD MIN_INCENTIVE
    if atFloor < D ∨ (seized = U ∧ (repaid < d ∨ other = true)) then some 0 else do
      let seizedAssets ← mulDiv (← mulDiv C seized U) unit price
      if repaid < seizedAssets then mulDiv seizedAssets feeWad WAD else some 0

/-- No fee only when the call writes debt off, as in the first fee commit (56985efa): a position under 1.02 × its
debts still pays on a call that leaves units. -/
def feeWithoutFloor : FeeRule := fun C _ d price unit U seized repaid feeWad other =>
  if feeWad = 0 ∨ seized = 0 then some 0 else do
    if seized = U ∧ (repaid < d ∨ other = true) then some 0 else do
      let seizedAssets ← mulDiv (← mulDiv C seized U) unit price
      if repaid < seizedAssets then mulDiv (seizedAssets - repaid) feeWad WAD else some 0

/-- The gain left in USD, never converted to the repaid asset. -/
def feeInUsd : FeeRule := fun C D d _ _ U seized repaid feeWad other =>
  if feeWad = 0 ∨ seized = 0 then some 0 else do
    let atFloor ← mulDiv C WAD MIN_INCENTIVE
    if atFloor < D ∨ (seized = U ∧ (repaid < d ∨ other = true)) then some 0 else do
      let seizedUsd ← mulDiv C seized U
      if repaid < seizedUsd then mulDiv (seizedUsd - repaid) feeWad WAD else some 0

/-- 60 of 100 units worth 100, at a price of 1, for 50 repaid: a 10% fee on the gain of 10 is 1, not 6. -/
theorem f1_rejects_feeOnSeized : ¬ FeeAtMostShareOfGain feeOnSeized := by
  intro h
  have := h 100 0 50 1 1 100 60 50 (10 ^ 17) false 6 (by decide)
  norm_num [WAD] at this

/-- The same liquidation of a position owing 100 against collateral worth 100, under 1.02 × its debts. -/
theorem f2_rejects_feeWithoutFloor : ¬ NoFeeOnBadDebt feeWithoutFloor := by
  intro h
  have := (h 100 100 50 1 1 100 60 50 (10 ^ 17) false 1 (by decide)).1 (by decide)
  exact absurd this (by decide)

/-- A token with one decimal: 60 units worth 60 USD are 600 of it, for 10 repaid. The fee is 59, not 5. -/
theorem f3_rejects_feeInUsd : ¬ FeeLosesOnlyRounding feeInUsd := by
  intro h
  have := h 100 0 10 1 10 100 60 10 (10 ^ 17) false 5 (by decide) (by decide) (by decide) (by decide) (by decide)
  norm_num [WAD] at this

/-! ## The health check and the adapters -/

/-- A check of the two diagonal corners only (both prices down, both up). -/
def diagonalCheck : Check := fun V p σ d others pen =>
  ∀ c ∈ [(p.1 / σ.1, p.2 / σ.2), (p.1 * σ.1, p.2 * σ.2)], pen * debtsAt d others c ≤ V c

/-- A check that values the debts at the oracle's prices instead of each corner's. -/
def oracleDebtsCheck : Check := fun V p σ d others pen =>
  ∀ c ∈ corners p σ, pen * debtsAt d others p ≤ V c

/-- Holding only token0 is linear in prices, so concave. -/
theorem token0Concave : ValueConcave (fun q => q.1) :=
  ⟨(convex_Ioi 0).prod (convex_Ioi 0), fun _ _ _ _ _ _ _ _ _ => by simp⟩

/-- 1 wei of token0 against a debt in token1, prices 1 and σ 2: the diagonal corners pass, but token0 at ½ with
token1 at 2 leaves the position underwater. -/
theorem h1_rejects_diagonalCheck : ¬ CheckCoversBox diagonalCheck := by
  intro h
  have := h (fun q => q.1) (1, 1) (2, 2) (0, 1) 0 1 token0Concave (by norm_num) (by norm_num) (by norm_num)
    (by norm_num) (by norm_num) (by norm_num) (by norm_num)
    (by simp only [diagonalCheck, List.mem_cons, List.mem_nil_iff, or_false, forall_eq_or_imp, forall_eq,
          debtsAt]; norm_num)
    (1 / 2, 2) (by simp only [box, Set.mem_prod, Set.mem_Icc]; norm_num) 0 le_rfl
  norm_num [debtsAt] at this

/-- The same position, owing ½ of token1: worth ½ at every corner, as much as its debt at the oracle's prices. -/
theorem h1_rejects_oracleDebtsCheck : ¬ CheckCoversBox oracleDebtsCheck := by
  intro h
  have := h (fun q => q.1) (1, 1) (2, 2) (0, 1 / 2) 0 1 token0Concave (by norm_num) (by norm_num) (by norm_num)
    (by norm_num) (by norm_num) (by norm_num) (by norm_num)
    (by simp only [oracleDebtsCheck, corners, List.mem_cons, List.mem_nil_iff, or_false, forall_eq_or_imp,
          forall_eq, debtsAt]; norm_num)
    (1 / 2, 2) (by simp only [box, Set.mem_prod, Set.mem_Icc]; norm_num) 0 le_rfl
  norm_num [debtsAt] at this

/-- The value at √(pY / pX): the two tokens swapped. -/
noncomputable def rangeValueSwapped (a b L : ℝ) (p : ℝ × ℝ) : ℝ :=
  let h := holdings a b L (Real.sqrt (p.2 / p.1))
  h.1 * p.1 + h.2 * p.2

/-- Range [1, 4], liquidity 1: worth 48 at prices (1, 16) and 12 at (16, 1), but 51/8 halfway, at (17/2, 17/2). -/
theorem a2_rejects_rangeValueSwapped : ¬ RangeValueConcave rangeValueSwapped := by
  intro h
  have hv : ConcaveOn ℝ (Set.Ioi 0 ×ˢ Set.Ioi 0) (rangeValueSwapped 1 4 1) :=
    h 1 4 1 (by norm_num) (by norm_num) (by norm_num)
  have hc := hv.2 (show ((1 : ℝ), (16 : ℝ)) ∈ Set.Ioi 0 ×ˢ Set.Ioi 0 from ⟨by norm_num, by norm_num⟩)
    (show ((16 : ℝ), (1 : ℝ)) ∈ Set.Ioi 0 ×ˢ Set.Ioi 0 from ⟨by norm_num, by norm_num⟩)
    (show (0 : ℝ) ≤ 1 / 2 by norm_num) (show (0 : ℝ) ≤ 1 / 2 by norm_num) (by norm_num)
  have r16 : Real.sqrt 16 = 4 := by
    rw [show (16 : ℝ) = 4 ^ 2 by norm_num, Real.sqrt_sq (by norm_num)]
  have r16' : Real.sqrt 16⁻¹ = 4⁻¹ := by rw [Real.sqrt_inv, r16]
  norm_num [rangeValueSwapped, holdings, r16, r16'] at hc

/-- `liquidityOf` rounding up. -/
def liquidityRoundsUp : AmountsAt := fun a b T u N s => do
  let L ← if N = 0 then some 0 else do toU128 (← mulDivUp u T N)
  rangeAt a b L s

/-- `liquidityOf` without its guard for a position with no units: it divides by zero. -/
def liquidityUnguarded : AmountsAt := fun a b T u N s => do
  rangeAt a b (← toU128 (← mulDiv u T N)) s

/-- Half of 3 liquidity, all in token1: reports 2 where it holds 1.5. -/
theorem a1_rejects_liquidityRoundsUp : ¬ NeverOverReports liquidityRoundsUp := by
  intro h
  have := (h Q96 (2 * Q96) 3 1 2 (2 * Q96) 0 2 (by unfold Q96; norm_num) (by unfold Q96; norm_num) (by norm_num)
    (by norm_num) (by decide)).2.1
  norm_num [exactAt, holdings, Q96] at this

/-- No units at all. -/
theorem a3_rejects_liquidityUnguarded : ¬ NeverReverts liquidityUnguarded := by
  intro h
  obtain ⟨_, hr⟩ := h 1 2 0 0 0 0 (by norm_num) (by norm_num) (by unfold U160; norm_num) (by unfold U160; norm_num)
    (by unfold U128; norm_num) le_rfl
  simp [liquidityUnguarded, mulDiv] at hr

/-- Two halves of 1 liquidity each round up to 1, so each holds what the whole does. -/
theorem a4_rejects_liquidityRoundsUp : ¬ SplittingAddsNothing liquidityRoundsUp := by
  intro h
  have := h Q96 (2 * Q96) 1 1 1 2 (2 * Q96) 0 1 0 1 0 1 le_rfl (by decide) (by decide) (by decide)
  omega

/-! ## The fee ledger

Two accounts, `0` and `1`. -/

section Fees

open FeeModel

theorem eq_some_getD' {α : Type} {o : Option α} (d : α) (h : o.isSome = true) : o = some (o.getD d) := by
  cases o <;> simp_all

/-- A checkpoint with the gain rounded up. -/
def feeCheckpointUp (s : FeeState (Fin 2)) (a : Fin 2) : Option (FeeState (Fin 2)) := do
  let owed ← if s.units a = 0 then some (s.owed a) else do
    let gained ← mulDivUp (s.units a) ((s.growth + U256 - s.mark a) % U256) Q128
    let o ← add256 (s.owed a) gained
    toU128 o
  pure { s with owed := Function.update s.owed a owed, mark := Function.update s.mark a s.growth }

def feesGainUp : Fees (Fin 2) := { senzuFees (Fin 2) with checkpoint := feeCheckpointUp }

/-- Two holders of a unit each, and 1 arrives: each is credited half a fee rounded up, 2 owed and 1 held. -/
theorem fl1_rejects_feesGainUp : ¬ FeesCollectable feesGainUp := by
  intro h
  have := (h [.mint 0 1, .mint 1 1, .accrue 1, .mint 0 0, .mint 1 0] _ _ (eq_some_getD' (FeeState.empty _, 0)
    (by decide))).1
  exact absurd this (by decide)

/-- A poke that books the DEX's fees without collecting them, so the next poke books them again. -/
def pokeKeepsPending (s : FeeState (Fin 2)) : Option (FeeState (Fin 2)) :=
  if s.pending = 0 then some s else do
    let held ← add128 s.held s.pending
    let x ← mulDiv s.pending Q128 s.total
    let growth ← add256 s.growth x
    pure { s with held, growth }

def feesBookTwice : Fees (Fin 2) := { senzuFees (Fin 2) with poke := pokeKeepsPending }

/-- A holder's position earns 10 and the holder collects twice: 20 paid. -/
theorem fl2_rejects_feesBookTwice : ¬ FeesPaidAtMostEarned feesBookTwice := by
  intro h
  have := h [.mint 0 1, .accrue 10, .collect 0, .collect 0] _ _ (eq_some_getD' (FeeState.empty _, 0) (by decide))
  exact absurd this (by decide)

/-- A poke that divides by one unit fewer than the position has. -/
def pokeOneUnitShort (s : FeeState (Fin 2)) : Option (FeeState (Fin 2)) :=
  if s.pending = 0 then some s else do
    let held ← add128 s.held s.pending
    let x ← mulDiv s.pending Q128 (s.total - 1)
    let growth ← add256 s.growth x
    pure { s with held, growth, pending := 0 }

def feesOneUnitShort : Fees (Fin 2) := { senzuFees (Fin 2) with poke := pokeOneUnitShort }

/-! FL3's case, step by step: account 0 holds both of a position's units, which the DEX owes 1. -/

def shortStart : FeeState (Fin 2) :=
  { FeeState.empty (Fin 2) with units := Function.update (fun _ => 0) 0 2, pending := 1 }
def short₁ : FeeState (Fin 2) := (FeeModel.checkpoint shortStart 0).getD shortStart
def short₂ : FeeState (Fin 2) := (pokeOneUnitShort short₁).getD shortStart
def short₃ : FeeState (Fin 2) := (FeeModel.checkpoint short₂ 0).getD shortStart

/-- Its share is the 1 owed; dividing by one unit fewer credits it 2. -/
theorem fl3_rejects_feesOneUnitShort : ¬ FeesCreditedAtMostItsShare feesOneUnitShort := by
  intro h
  have := h shortStart 0 short₁ short₂ short₃ (eq_some_getD' _ (by decide)) (eq_some_getD' _ (by decide))
    (eq_some_getD' _ (by decide))
  have e₃ : short₃.owed 0 = 2 := by decide
  have e₁ : short₁.owed 0 = 0 := by decide
  have u : short₁.units 0 = 2 := by decide
  have p : short₁.pending = 1 := by decide
  have tot : short₁.total = 2 := by decide
  rw [e₃, e₁, u, p, tot] at this
  norm_num at this

/-- A seize that moves the bookmark and the units but leaves the source's credited fees behind (the code before
2026-11-24's review). -/
def seizeKeepsOwed (s : FeeState (Fin 2)) (src dst : Fin 2) (n : ℕ) : Option (FeeState (Fin 2)) :=
  if src = dst ∨ n = 0 then some s else do
    let units ← sub (s.units src) n
    let g ← preview s
    let mark ← mergeMark (s.mark dst) (s.mark src) (s.units dst) n g
    pure { s with
      mark := Function.update s.mark dst mark,
      units := Function.update (Function.update s.units src units) dst (s.units dst + n) }

def feesSeizeKeepsOwed : Fees (Fin 2) := { senzuFees (Fin 2) with seize := seizeKeepsOwed }

/-! S1's case: account 0 holds 2 units and has been credited all 10 of the position's fees; half its units go to
account 1. -/

def keepsOwedRun : Option (FeeState (Fin 2) × ℕ) :=
  feesSeizeKeepsOwed.run (FeeState.empty _) [.mint 0 2, .accrue 10, .mint 0 0]
def keepsOwed₀ : FeeState (Fin 2) × ℕ := keepsOwedRun.getD (FeeState.empty _, 0)
def keepsOwed₁ : FeeState (Fin 2) := (seizeKeepsOwed keepsOwed₀.1 0 1 1).getD (FeeState.empty _)

/-- Account 1's share is 5 fees; it gets none. -/
theorem s1_rejects_feesSeizeKeepsOwed : ¬ SeizeMovesItsShare feesSeizeKeepsOwed := by
  intro h
  have := (h [.mint 0 2, .accrue 10, .mint 0 0] keepsOwed₀.1 keepsOwed₀.2
    (eq_some_getD' (FeeState.empty _, 0) (by decide)) 0 1 1
    (5 * Q128) keepsOwed₁ (by decide) (by decide) (eq_some_getD' _ (by decide))).2.1
  have a : claimAt keepsOwed₀.1 (5 * Q128) 1 = 0 := by decide
  have b : claimAt keepsOwed₀.1 (5 * Q128) 0 = 10 * Q128 := by decide
  have c : keepsOwed₀.1.units 0 = 2 := by decide
  have d : claimAt keepsOwed₁ (5 * Q128) 1 = 0 := by decide
  have e : keepsOwed₀.1.units 1 = 0 := by decide
  rw [a, b, c, d, e] at this
  norm_num [Q128] at this

/-- A seize that divides the credited fees by the receiver's units instead of the source's. -/
def seizeByReceiver (s : FeeState (Fin 2)) (src dst : Fin 2) (n : ℕ) : Option (FeeState (Fin 2)) :=
  if src = dst ∨ n = 0 then some s else do
    let units ← sub (s.units src) n
    let g ← preview s
    let mark ← mergeMark (s.mark dst) (s.mark src) (s.units dst) n g
    let moved ← if s.units src = 0 ∨ s.owed src = 0 then some 0
      else if s.units src ≤ n then some (s.owed src)
      else mulDiv (s.owed src) n (s.units dst)
    let dstOwed ← add128 (s.owed dst) moved
    let owed := Function.update (Function.update s.owed src (s.owed src - moved)) dst dstOwed
    pure { s with
      mark := Function.update s.mark dst mark, owed,
      units := Function.update (Function.update s.units src units) dst (s.units dst + n) }

def feesSeizeByReceiver : Fees (Fin 2) := { senzuFees (Fin 2) with seize := seizeByReceiver }

def byReceiver₀ : FeeState (Fin 2) × ℕ :=
  (feesSeizeByReceiver.run (FeeState.empty _) [.mint 0 2, .accrue 10, .mint 0 0]).getD (FeeState.empty _, 0)

/-- The same case, to a receiver with no units yet (a liquidator's first seize): it divides by zero and reverts. -/
theorem s2_rejects_feesSeizeByReceiver : ¬ SeizeNeverReverts feesSeizeByReceiver := by
  intro h
  have := h [.mint 0 2, .accrue 10, .mint 0 0] byReceiver₀.1 byReceiver₀.2
    (eq_some_getD' (FeeState.empty _, 0) (by decide))
    (by decide) 0 1 1 (5 * Q128) (by decide) (by decide)
  exact this (Option.isNone_iff_eq_none.mp (by decide))

end Fees

end Senzu.Mutants
