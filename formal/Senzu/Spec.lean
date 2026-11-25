import Mathlib.Algebra.Order.Field.Rat
import Senzu.Fees
import Senzu.Liquidation
import Senzu.Rewards
import Senzu.Range

/-!
# Frozen statements

What we claim, with no proofs. `scripts/check.sh` fails if this file changes without `Spec.lock` being updated
too, so a change to a statement shows up in review. Proofs live in `Senzu/Proofs/` and `Check.lean` binds each
statement to its proof for `senzu`; `Mutants.lean` shows each statement rejects at least one wrong wiring.

Each statement takes the wiring (`Lending`, or a conversion function) as an argument, so the same statement
can be proved for `senzu` and refuted for a mutant. Exact values are rationals: `sharePrice` is the price of
one share with the virtual shares and assets, and the `exact*` functions are the conversions without rounding.
-/

namespace Senzu.Spec

/-- Assets per share, virtual shares and assets included. -/
def sharePrice (assets shares : Nat) : ℚ :=
  ((assets + VIRTUAL_ASSETS : Nat) : ℚ) / ((shares + VIRTUAL_SHARES : Nat) : ℚ)

/-- `toShares` without rounding. -/
def exactShares (x assets shares : Nat) : ℚ :=
  (x : ℚ) * ((shares + VIRTUAL_SHARES : Nat) : ℚ) / ((assets + VIRTUAL_ASSETS : Nat) : ℚ)

/-- `toAssets` without rounding. -/
def exactAssets (x assets shares : Nat) : ℚ :=
  (x : ℚ) * ((assets + VIRTUAL_ASSETS : Nat) : ℚ) / ((shares + VIRTUAL_SHARES : Nat) : ℚ)

/-! ## Conversions -/

/-- **C1.** `toShares` rounded down is at most the exact value and less than 1 below it; rounded up, at least
the exact value and less than 1 above it. -/
def SharesRounding (conv : Nat → Nat → Nat → Rounding → Option Nat) : Prop :=
  ∀ x a s r,
    (conv x a s .down = some r → (r : ℚ) ≤ exactShares x a s ∧ exactShares x a s < r + 1) ∧
    (conv x a s .up = some r → exactShares x a s ≤ r ∧ (r : ℚ) < exactShares x a s + 1)

/-- **C2.** The same for `toAssets`. -/
def AssetsRounding (conv : Nat → Nat → Nat → Rounding → Option Nat) : Prop :=
  ∀ x a s r,
    (conv x a s .down = some r → (r : ℚ) ≤ exactAssets x a s ∧ exactAssets x a s < r + 1) ∧
    (conv x a s .up = some r → exactAssets x a s ≤ r ∧ (r : ℚ) < exactAssets x a s + 1)

/-! ## Lenders -/

/-- **L1.** Supplying `x` and withdrawing the shares it minted returns at most `x`. -/
def SupplyWithdrawRoundTrip (l : Lending) : Prop :=
  ∀ x a s minted back,
    l.supplyShares x a s = some minted →
    l.withdrawAssets minted (a + x) (s + minted) = some back →
    back ≤ x

/-- **L2.** That round trip loses less than one share's price plus one unit of the asset. -/
def RoundTripLoss (l : Lending) : Prop :=
  ∀ x a s minted back,
    l.supplyShares x a s = some minted →
    l.withdrawAssets minted (a + x) (s + minted) = some back →
    (x : ℚ) - back < sharePrice a s + 1

/-- **L3.** No supply, withdrawal or accrual lowers the share price. -/
def PriceNeverFalls (l : Lending) : Prop :=
  ∀ p act p' out,
    l.step p act = some (p', out) →
    sharePrice p.assets p.shares ≤ sharePrice p'.assets p'.shares

/-- **L4.** No sequence of them does either. -/
def PriceNeverFallsOverAnySequence (l : Lending) : Prop :=
  ∀ p acts p' out,
    l.run p acts = some (p', out) →
    sharePrice p.assets p.shares ≤ sharePrice p'.assets p'.shares

/-- **L5. No free lunch.** Whatever lenders do, in any order and any number of times, the assets they take out
net of what they put in are at most the shares they burned, valued at the starting share price, plus the
interest added meanwhile. Holders who don't act keep their shares, so this bounds what anyone can take from
them. -/
def NoFreeLunch (l : Lending) : Prop :=
  ∀ p acts p' out,
    l.run p acts = some (p', out) →
    (out : ℚ) ≤ sharePrice p.assets p.shares * ((p.shares : ℚ) - p'.shares) + interestOf acts

/-! ## Borrowers -/

/-- **B1.** Right after borrowing `d`, the position owes at least `d`. -/
def BorrowOwesAtLeastBorrowed (l : Lending) : Prop :=
  ∀ d a s minted owed,
    l.borrowShares d a s = some minted →
    l.debtOf minted (a + d) (s + minted) = some owed →
    d ≤ owed

/-- **B2.** Repaying `x`, less than the whole debt, burns borrow shares worth at most `x` at the current price. -/
def RepayNeverOverCredits (l : Lending) : Prop :=
  ∀ x a s burned,
    l.repayShares x a s = some burned →
    (burned : ℚ) * sharePrice a s ≤ x

/-! ## Bad debt and solvency

Each statement takes the write-off (`writeOff` for Senzu) as an argument. -/

/-- Assets owed per borrow share, virtual shares and assets included. -/
def debtPrice (m : Market) : ℚ := sharePrice m.totalBorrowAssets m.totalBorrowShares

/-- **M1. A market can't be bricked.** Through any sequence of supplies, withdrawals, borrows, repayments,
write-offs and accruals, borrows never exceed supply, so `cash()` never underflows and withdrawals and borrows
keep working. -/
def CashNeverNegative (wo : Market → Nat → Option (Nat × Market)) : Prop :=
  ∀ m acts m',
    m.totalBorrowAssets ≤ m.totalSupplyAssets →
    marketRun wo m acts = some m' →
    m'.totalBorrowAssets ≤ m'.totalSupplyAssets

/-- **W1.** A write-off that leaves other borrow shares takes from lenders less than the position's exact debt
plus 1 wei. -/
def WriteOffCostsAtMostTheDebt (wo : Market → Nat → Option (Nat × Market)) : Prop :=
  ∀ m q debt m',
    wo m q = some (debt, m') → q < m.totalBorrowShares →
    (m.totalSupplyAssets : ℚ) - m'.totalSupplyAssets <
      exactAssets q m.totalBorrowAssets m.totalBorrowShares + 1

/-- **W2.** Borrowing `d` and being written off right away takes from lenders less than `d` plus one borrow
share's price plus 1 wei, in a market with no debt that no one owes (B5 and W4 keep it so). Repeated, as in
the emptied-market attack, each round takes at most about 1 wei beyond what was borrowed. -/
def BorrowThenWriteOff (wo : Market → Nat → Option (Nat × Market)) : Prop :=
  ∀ m d fee supplyShares minted feeShares m₁ debt m₂,
    addDebt m d fee supplyShares = some (minted, feeShares, m₁) →
    wo m₁ minted = some (debt, m₂) →
    (m.totalBorrowShares = 0 → m.totalBorrowAssets = 0) →
    (m.totalSupplyAssets : ℚ) - m₂.totalSupplyAssets < d + debtPrice m + 1

/-- **W3.** A write-off charges no other borrower: when other borrow shares are left, unless it exceeds
`totalBorrowAssets`, it doesn't raise the debt per borrow share. -/
def WriteOffChargesNoOneElse (wo : Market → Nat → Option (Nat × Market)) : Prop :=
  ∀ m q debt m',
    wo m q = some (debt, m') →
    debt ≤ m.totalBorrowAssets → q < m.totalBorrowShares →
    debtPrice m' ≤ debtPrice m

/-- **W4.** Writing off a market's last borrow shares leaves it no debt: none is left that no one owes. -/
def LastWriteOffLeavesNoDebt (wo : Market → Nat → Option (Nat × Market)) : Prop :=
  ∀ m debt m', wo m m.totalBorrowShares = some (debt, m') → m'.totalBorrowAssets = 0

/-! ## Repayments

Each statement takes the repayment's booking (`repay` for Senzu) as an argument: the market after burning the
position's shares for what it paid. -/

/-- **B3.** A repayment that leaves shares never lowers the debt per borrow share (audit H-01: booking the
rounded-up payment let one-share debts empty the market's debt while shares were left, and the next borrow minted
shares without limit). The repayment of the last shares empties the market instead (B5). -/
def RepayNeverLowersDebtPrice (rp : Market → Nat → Nat → Option Market) : Prop :=
  ∀ m q x r m', q ≤ m.totalBorrowShares → repayAmounts m q x = some r → r.2 < m.totalBorrowShares →
    rp m r.2 r.1 = some m' → debtPrice m ≤ debtPrice m'

/-- **B5.** The repayment of a market's last borrow shares leaves it no debt: none is left that no one owes. -/
def LastRepayLeavesNoDebt (rp : Market → Nat → Nat → Option Market) : Prop :=
  ∀ m q x r m', q ≤ m.totalBorrowShares → repayAmounts m q x = some r → r.2 = m.totalBorrowShares →
    rp m r.2 r.1 = some m' → m'.totalBorrowAssets = 0

/-- **B4.** A repayment adds what it paid to the market's cash, every wei. -/
def RepayPaysLenders (rp : Market → Nat → Nat → Option Market) : Prop :=
  ∀ m q x r m', q ≤ m.totalBorrowShares → repayAmounts m q x = some r → rp m r.2 r.1 = some m' →
    (m'.totalSupplyAssets : ℤ) - m'.totalBorrowAssets = (m.totalSupplyAssets : ℤ) - m.totalBorrowAssets + r.1

/-! ## Rewards

Each statement takes the reward ledger (`senzuRewards` for Senzu) as an argument. -/

/-- **R1. Nothing gets stuck** (audit H-03). After any steps, every checkpoint is at most its position's growth
as of now, whatever the DEX previews, so no checkpoint's subtraction reverts; and a payout never reverts. -/
def NothingStuck (r : Rewards) : Prop :=
  ∀ acts L paid, r.run Ledger.empty acts = some (L, paid) →
    (∀ account lp unbooked g, r.growth L lp unbooked = some g → (L.checkpoints account lp).growth ≤ g) ∧
    ∀ account lp, r.pay L account lp ≠ none

/-- **R2.** A position's holders are paid at most what arrived for it (audit H-02). -/
def PaidAtMostArrived (r : Rewards) : Prop :=
  ∀ acts L paid lp, r.run Ledger.empty acts = some (L, paid) → paid lp ≤ arrivedFor lp acts

/-- **R3.** Through a booking, a holder whose units don't change is credited at most its units' share of what
arrived: it is never credited from its co-holders' rewards. -/
def CreditedAtMostItsShare (r : Rewards) : Prop :=
  ∀ L account lp balance L₁ arrived liquidity L₂ L₃,
    r.checkpoint L account lp balance = some L₁ →
    r.book L₁ lp arrived liquidity = some L₂ →
    r.checkpoint L₂ account lp balance = some L₃ →
    ((L₃.checkpoints account lp).owed : ℚ) ≤
      (L₁.checkpoints account lp).owed + balance * arrived / liquidity

/-! ## The fee ledger

One position's fees in one token, over any finite set of accounts `A`. Each statement takes the fee ledger
(`senzuFees A` for Senzu) as an argument. `preview` is `_previewGrowth`: the booked growth plus what the DEX owes,
per unit. -/

section Fees

open FeeModel

variable {A : Type} [Fintype A] [DecidableEq A]

/-- **FL1. Every holder can collect.** After any steps from a new position, everything credited is at most what
the position holds; and a holder poked and checkpointed is owed at most that, so its payout never reverts. -/
def FeesCollectable (f : Fees A) : Prop :=
  ∀ acts s paid, f.run (FeeState.empty A) acts = some (s, paid) →
    ∑ a, s.owed a ≤ s.held ∧
      ∀ a s₁ s₂, f.poke s = some s₁ → f.checkpoint s₁ a = some s₂ → s₂.owed a ≤ s₂.held

/-- **FL2.** Everything paid out is at most what the DEX earned for the position. -/
def FeesPaidAtMostEarned (f : Fees A) : Prop :=
  ∀ acts s paid, f.run (FeeState.empty A) acts = some (s, paid) → paid ≤ earned acts

/-- **FL3.** Through a poke, a holder whose units don't change is credited at most its units' share of what the DEX
paid: never from its co-holders' fees. -/
def FeesCreditedAtMostItsShare (f : Fees A) : Prop :=
  ∀ s a s₁ s₂ s₃, f.checkpoint s a = some s₁ → f.poke s₁ = some s₂ → f.checkpoint s₂ a = some s₃ →
    (s₃.owed a : ℚ) ≤ s₁.owed a + s₁.units a * s₁.pending / s₁.total

/-- **S1. A seize moves the seized units' share.** After any steps, seizing `n` of `src`'s units for `dst` moves
their share of what `src` could collect, credited fees included (`claimAt`, at the preview): the two claims after
add up to at most before; `dst` gains its share of `src`'s claim, less under one wei (×2^128) and one growth unit
per unit it holds after; and seizing all of `src`'s units leaves it nothing. -/
def SeizeMovesItsShare (f : Fees A) : Prop :=
  ∀ acts s paid, f.run (FeeState.empty A) acts = some (s, paid) →
    ∀ src dst n P s', src ≠ dst → preview s = some P → f.seize s src dst n = some s' →
      claimAt s' P src + claimAt s' P dst ≤ claimAt s P src + claimAt s P dst ∧
        (claimAt s P dst : ℚ) + n * claimAt s P src / s.units src ≤
          claimAt s' P dst + Q128 + (s.units dst + n) ∧
        (0 < n → n = s.units src → claimAt s' P src = 0)

/-- **S2. A seize never reverts**, so the fee ledger never blocks a liquidation: after any steps, seizing at most
the source's units succeeds, while the units fit in 256 bits and the preview does. -/
def SeizeNeverReverts (f : Fees A) : Prop :=
  ∀ acts s paid, f.run (FeeState.empty A) acts = some (s, paid) → s.total < U256 →
    ∀ src dst n P, n ≤ s.units src → preview s = some P → f.seize s src dst n ≠ none

end Fees

/-! ## Liquidations

`liquidate` takes the health check's numbers, in USD with 18 decimals: `C` for the position's `U` units and `D` for
all its debts. The debt repaid is `d` assets at `price` (USD per whole token), `unit` = 10 ^ its decimals. -/

/-- **Q1. A liquidator never takes too much.** A liquidation repays at most the debt and what the liquidator
offered, takes at most the position's units, and takes units worth at most what it repaid × the penalty the
position bears. -/
def LiquidatorTakesNoMore (l : Liquidation) : Prop :=
  ∀ C D d price unit pen maxRepay U seized repaid b, MIN_INCENTIVE ≤ pen →
    l.liquidate C D d price unit pen maxRepay U = some (seized, repaid) → l.bearable C D pen = some b →
    repaid ≤ d ∧ repaid ≤ maxRepay ∧ seized ≤ U ∧
      (seized : ℚ) * C / U ≤ (repaid : ℚ) * price / unit * b / WAD

/-- What Q2 allows a liquidation to cost lenders: the adapter's rounding, and, at the penalty borne `b`, two wei
and one borrow share's price of the repaid debt plus 10^-18 USD. -/
def liquidationRounding (m : Market) (adapterRounding : ℚ) (b price unit : Nat) : ℚ :=
  adapterRounding + (b : ℚ) / WAD * ((debtPrice m + 2) * price / unit + 1)

/-- A liquidation of a position owing `q` of market `m`'s borrow shares and other debts worth `others`, repaid in
the market. `D` and `D'` are its debts in USD before and after, `b` the penalty it bore, and `C'` what the units it
keeps are worth: at least their share of `C` less `adapterRounding`, what the adapter's rounding loses on a slice
of units (ASSUMPTIONS.md gives Senzu's adapters'). A position with collateral has units, and the penalty is at least
`MIN_INCENTIVE`, as `SenzuRiskConfig` keeps it. -/
def Liquidated (l : Liquidation) (m : Market) (q C D others price unit pen maxRepay U b C' D' : Nat)
    (adapterRounding : ℚ) : Prop :=
  ∃ d Dd seized repaid r m' d' Dd',
    0 < U ∧ MIN_INCENTIVE ≤ pen ∧ q ≤ m.totalBorrowShares ∧
    toAssets q m.totalBorrowAssets m.totalBorrowShares .up = some d ∧
    mulDivUp d price unit = some Dd ∧ D = Dd + others ∧
    l.bearable C D pen = some b ∧
    l.liquidate C D d price unit pen maxRepay U = some (seized, repaid) ∧
    repayAmounts m q repaid = some r ∧ repay m r.2 r.1 = some m' ∧
    toAssets (q - r.2) m'.totalBorrowAssets m'.totalBorrowShares .up = some d' ∧
    mulDivUp d' price unit = some Dd' ∧ D' = Dd' + others ∧
    ((U - seized : Nat) : ℚ) * C / U ≤ C' + adapterRounding

/-- **Q2. A liquidation costs lenders only rounding.** Collateral less debts × the penalty borne falls by at most
`liquidationRounding`. -/
def LendersLoseOnlyRounding (l : Liquidation) : Prop :=
  ∀ m q C D others price unit pen maxRepay U b C' D' ε,
    Liquidated l m q C D others price unit pen maxRepay U b C' D' ε →
    (C : ℚ) - (b : ℚ) / WAD * D - liquidationRounding m ε b price unit ≤ C' - (b : ℚ) / WAD * D'

/-- **Q3. Rounding can't push a covered position underwater unless it's dust.** A position with collateral at least
1.02 × its debts still has collateral ≥ debts after a liquidation, unless 2% of the debts left are under Q2's
rounding. -/
def CoveredStaysCovered (l : Liquidation) : Prop :=
  ∀ m q C D others price unit pen maxRepay U b C' D' ε,
    Liquidated l m q C D others price unit pen maxRepay U b C' D' ε →
    MIN_INCENTIVE * D ≤ C * WAD →
    liquidationRounding m ε b price unit ≤ ((MIN_INCENTIVE - WAD : Nat) : ℚ) / WAD * D' → D' ≤ C'

/-- **Q4. Dust can't block a liquidation (audit M-02).** While a borrow share is worth at most 1 wei, a position
with collateral can be liquidated: repaying its whole debt reverts neither in the liquidation nor in the market.
Within bounds every real position is under (USD values and the debt's unit below 2^120, units and the market's
numbers in their 128 bits, borrows within supply, as M1 keeps them). It may take no units: a debt worth less than
a unit is repaid for nothing. -/
def DustNeverBlocks (l : Liquidation) : Prop :=
  ∀ (m : Market) q C others price unit pen U d Dd,
    0 < q → q ≤ m.totalBorrowShares → m.totalBorrowShares < U128 →
    m.totalBorrowAssets + VIRTUAL_ASSETS ≤ m.totalBorrowShares + VIRTUAL_SHARES →
    m.totalBorrowAssets ≤ m.totalSupplyAssets → m.totalSupplyAssets + d < U128 →
    toAssets q m.totalBorrowAssets m.totalBorrowShares .up = some d → mulDivUp d price unit = some Dd →
    0 < C → 0 < price → 0 < unit → MIN_INCENTIVE ≤ pen → pen ≤ MAX_PENALTY →
    C < 2 ^ 120 → Dd + others < 2 ^ 120 → U < U128 → unit < 2 ^ 120 →
    ∃ seized repaid r m', l.liquidate C (Dd + others) d price unit pen d U = some (seized, repaid) ∧
      repayAmounts m q repaid = some r ∧ repay m r.2 r.1 = some m'

/-! ## The liquidation fee

A `FeeRule` takes a seize's result: `seized` of the position's `U` units for `repaid` of the debt's `d` assets, with
`C`, `D`, `price` and `unit` as above, the DEX's `feeWad` (1e18 = 100%) and whether another debt remains (`other`).
The liquidator pays the fee on top of `repaid`, so the borrower pays the same whatever it is. Its lender shares are
a supply (L3, L4). -/

/-- **F1. The fee is at most its share of what the liquidator gained.** At most `feeWad` of the seized units' worth
in the repaid asset less what was repaid, and nothing when that is not positive. -/
def FeeAtMostShareOfGain (fee : FeeRule) : Prop :=
  ∀ C D d price unit U seized repaid feeWad other f,
    fee C D d price unit U seized repaid feeWad other = some f →
    (f : ℚ) ≤ (feeWad : ℚ) / WAD * max 0 ((seized : ℚ) * C / U * unit / price - repaid)

/-- **F2. No fee on bad debt.** None when the position's collateral is under 1.02 × its debts (a write-off is
certain, whichever debt this call repays), and none when the liquidation takes every unit and leaves debt to write
off, of this market or another. -/
def NoFeeOnBadDebt (fee : FeeRule) : Prop :=
  ∀ C D d price unit U seized repaid feeWad other f,
    fee C D d price unit U seized repaid feeWad other = some f →
    (C * WAD < MIN_INCENTIVE * D → f = 0) ∧ (seized = U → (repaid < d ∨ other = true) → f = 0)

/-- **F3. The fee loses only rounding.** Wherever F2 allows a fee, it is more than its exact share of the gain less
1 wei and `feeWad` of (one USD-wei in the repaid asset + 1 wei): under 1.2 wei at the 20% cap. -/
def FeeLosesOnlyRounding (fee : FeeRule) : Prop :=
  ∀ C D d price unit U seized repaid feeWad other f,
    0 < feeWad → 0 < seized → MIN_INCENTIVE * D ≤ C * WAD → ¬ (seized = U ∧ (repaid < d ∨ other = true)) →
    fee C D d price unit U seized repaid feeWad other = some f →
    (feeWad : ℚ) / WAD * ((seized : ℚ) * C / U * unit / price - repaid)
      - (feeWad : ℚ) / WAD * ((unit : ℚ) / price + 1) - 1 < f

/-! ## The health check and what every adapter promises -/

/-- Every price pair between the corners. -/
noncomputable def box (p σ : ℝ × ℝ) : Set (ℝ × ℝ) :=
  Set.Icc (p.1 / σ.1) (p.1 * σ.1) ×ˢ Set.Icc (p.2 / σ.2) (p.2 * σ.2)

/-- Concave over all positive prices. -/
def ValueConcave (V : ℝ × ℝ → ℝ) : Prop :=
  ConcaveOn ℝ (Set.Ioi 0 ×ˢ Set.Ioi 0) V

/-- `holdings` with Uniswap's X96 √prices and a slice `units / totalUnits` of `totalLiq`. -/
noncomputable def exactAt (a b totalLiq units totalUnits s : Nat) : ℝ × ℝ :=
  holdings ((a : ℝ) / Q96) ((b : ℝ) / Q96) ((units : ℝ) * totalLiq / totalUnits) ((s : ℝ) / Q96)

/-- What one unit of liquidity holds at √price `s`. -/
noncomputable def oneLiquidityAt (a b s : Nat) : ℝ × ℝ :=
  holdings ((a : ℝ) / Q96) ((b : ℝ) / Q96) 1 ((s : ℝ) / Q96)

/-- The signature of a check, so a mutant can be plugged in instead of Senzu's. -/
abbrev Check := (ℝ × ℝ → ℝ) → ℝ × ℝ → ℝ × ℝ → ℝ × ℝ → ℝ → ℝ → Prop

/-- The signature of `amountsAt`, so a mutant can be plugged in instead of Senzu's. -/
abbrev AmountsAt := Nat → Nat → Nat → Nat → Nat → Nat → Option (Nat × Nat)

/-- **H1. Four corners cover the whole box.** A position whose value is concave in prices and passes the check is
worth at least the penalty × its debts at every price pair in the box, with other debts at or below their stressed
price. -/
def CheckCoversBox (check : Check) : Prop :=
  ∀ V p σ d others pen, ValueConcave V →
    0 < p.1 → 0 < p.2 → 1 ≤ σ.1 → 1 ≤ σ.2 → 0 ≤ d.1 → 0 ≤ d.2 → 0 ≤ pen →
    check V p σ d others pen →
    ∀ q ∈ box p σ, ∀ others' ≤ others, pen * debtsAt d others' q ≤ V q

/-- **A2. A range position's value is concave in prices.** So H1 applies to every adapter. -/
def RangeValueConcave (value : ℝ → ℝ → ℝ → ℝ × ℝ → ℝ) : Prop :=
  ∀ a b L, 0 < a → a < b → 0 ≤ L → ValueConcave (value a b L)

/-- **A1. `amountsAt` never over-reports, and under-reports by less than one unit of liquidity and 1 wei.** At the
√price the check passes it, each token amount is at most the exact holdings of the slice, and more than them
minus what one unit of liquidity holds minus 1 wei. -/
def NeverOverReports (at_ : AmountsAt) : Prop :=
  ∀ a b totalLiq units totalUnits s x y,
    0 < a → a < b → 0 < totalUnits → units ≤ totalUnits →
    at_ a b totalLiq units totalUnits s = some (x, y) →
    (x : ℝ) ≤ (exactAt a b totalLiq units totalUnits s).1 ∧
    (y : ℝ) ≤ (exactAt a b totalLiq units totalUnits s).2 ∧
    (exactAt a b totalLiq units totalUnits s).1 < x + (oneLiquidityAt a b s).1 + 1 ∧
    (exactAt a b totalLiq units totalUnits s).2 < y + (oneLiquidityAt a b s).2 + 1

/-- **A3. `amountsAt` never reverts** for any √price a `uint160` holds, any range within Uniswap's, any `uint128`
liquidity and any slice of the units. -/
def NeverReverts (at_ : AmountsAt) : Prop :=
  ∀ a b totalLiq units totalUnits s,
    0 < a → a < b → b < U160 → s < U160 → totalLiq < U128 → units ≤ totalUnits →
    ∃ h, at_ a b totalLiq units totalUnits s = some h

/-- **A4. Splitting units creates no value.** Two slices hold at most what their union holds, at any √price. -/
def SplittingAddsNothing (at_ : AmountsAt) : Prop :=
  ∀ a b totalLiq u v totalUnits s x₁ y₁ x₂ y₂ x y,
    u + v ≤ totalUnits →
    at_ a b totalLiq u totalUnits s = some (x₁, y₁) →
    at_ a b totalLiq v totalUnits s = some (x₂, y₂) →
    at_ a b totalLiq (u + v) totalUnits s = some (x, y) →
    x₁ + x₂ ≤ x ∧ y₁ + y₂ ≤ y

/-- How far the check's √price can fall below the exact one: 2^-95 below a ratio of 2^64 (the 96-bit root), 2^-63
above it. -/
noncomputable def sqrtError (q0 q1 scale0 scale1 : Nat) : ℝ :=
  if q0 * scale1 / (q1 * scale0) < 2 ^ 64 then (2 : ℝ) ^ (-95 : ℤ) else (2 : ℝ) ^ (-63 : ℤ)

/-- What valuing the holdings at a √price `δ` too low can add: holdings after arbitrage are the cheapest point of the
curve, so any other point is worth more, by at most 2·L·pY·(δ²/m + δ³/m²), `m` the larger of the range's lower √price
and the check's. -/
noncomputable def sqrtSlack (L pY δ m : ℝ) : ℝ :=
  2 * L * pY * (δ ^ 2 / m + δ ^ 3 / m ^ 2)

/-- **H2. The integer check over-values a corner by at most the √price's slack.** At any corner's prices (USD wad
per whole token, `scale` = 10^decimals), the collateral the check computes is at most the slice's exact value at those
prices plus `sqrtSlack`. With H1 and the debts rounding up, a position the check passes is covered across the box up
to it. -/
def CheckErrsOnlyBySqrtSlack (sqrtPrice : Nat → Nat → Nat → Nat → Option Nat)
    (collateral : Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → Nat → Option Nat) : Prop :=
  ∀ a b totalLiq units totalUnits q0 q1 scale0 scale1 s v,
    MIN_SQRT_PRICE ≤ a → a < b → b ≤ MAX_SQRT_PRICE → 0 < totalUnits → units ≤ totalUnits →
    0 < q0 → 0 < q1 → 0 < scale0 → 0 < scale1 →
    sqrtPrice q0 q1 scale0 scale1 = some s →
    collateral a b totalLiq units totalUnits q0 q1 scale0 scale1 = some v →
    (v : ℝ) ≤ rangeValue ((a : ℝ) / Q96) ((b : ℝ) / Q96) ((units : ℝ) * totalLiq / totalUnits)
        ((q0 : ℝ) / scale0, (q1 : ℝ) / scale1) +
      sqrtSlack ((units : ℝ) * totalLiq / totalUnits) ((q1 : ℝ) / scale1) (sqrtError q0 q1 scale0 scale1)
        (max ((a : ℝ) / Q96) ((s : ℝ) / Q96))

end Senzu.Spec
