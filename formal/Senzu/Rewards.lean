import Senzu.Evm

/-!
# The reward ledger

`RewardLedger`'s five steps, as the adapters use them: `book` is `_bookRewardGrowth`, `hold` is `_holdRewards`,
`checkpoint` is `_checkpointRewards`, `seize` is `seize`'s reward part, and `pay` is `_payRewards` before the
protocol's cut. Only what arrived is
booked; what the DEX would pay now (`rewardGrowth`'s `unbooked`) is a view. Each takes any arguments, so the
model allows more than an adapter does: a property proved for it holds whatever the adapter and the DEX do. The vectors (`reward_ledger`) compare it with
the Solidity over random sequences of steps, reverts included.
-/

namespace Senzu

def Q128 : Nat := 2 ^ 128

/-- `RewardLedger.RewardCheckpoint`. -/
structure RewardCheckpoint where
  growth : Nat
  owed : Nat
  deriving DecidableEq, Repr

/-- The ledger's storage: per position (`lpId`), and per account and position for checkpoints. -/
structure Ledger where
  /-- `rewardGrowthX128` -/
  growth : Nat → Nat
  /-- `positionRewards` -/
  positionRewards : Nat → Nat
  /-- `rewardsHeld` -/
  held : Nat
  /-- `rewardCheckpoints` -/
  checkpoints : Nat → Nat → RewardCheckpoint

/-- A new ledger: every slot 0. -/
def Ledger.empty : Ledger := ⟨fun _ => 0, fun _ => 0, 0, fun _ _ => ⟨0, 0⟩⟩

/-- `f` with `f k` set to `v`. -/
def setAt {α : Type} (f : Nat → α) (k : Nat) (v : α) : Nat → α := fun k' => if k' = k then v else f k'

/-- `rewardGrowth`, a view: booked plus what the DEX would pay now. -/
def rewardGrowth (L : Ledger) (lp unbooked : Nat) : Option Nat := add256 (L.growth lp) unbooked

/-- `_owed`: credited by the growth since the checkpoint. -/
def owed (cp : RewardCheckpoint) (balance growth : Nat) : Option Nat := do
  let dg ← sub growth cp.growth
  let gained ← mulDiv balance dg Q128
  add256 cp.owed gained

/-- `_bookRewardGrowth`. -/
def book (L : Ledger) (lp arrived liquidity : Nat) : Option Ledger :=
  if liquidity = 0 ∨ arrived = 0 then some L else do
    let x ← mulDiv arrived Q128 liquidity
    let growth ← add256 (L.growth lp) x
    let rewards ← add256 (L.positionRewards lp) arrived
    pure { L with
      growth := setAt L.growth lp growth
      positionRewards := setAt L.positionRewards lp rewards }

/-- `_holdRewards`. -/
def hold (L : Ledger) (amount : Nat) : Option Ledger := do
  let held ← add256 L.held amount
  pure { L with held }

/-- `_checkpointRewards`, at the booked growth. -/
def checkpoint (L : Ledger) (account lp balance : Nat) : Option Ledger := do
  let g := L.growth lp
  let o ← owed (L.checkpoints account lp) balance g
  pure { L with checkpoints := setAt L.checkpoints account (setAt (L.checkpoints account) lp ⟨g, o⟩) }

/-- `FeeLogic.mergeMark`: the bookmark of `held + units` units, `held` at `heldMark` and `units` at `movedMark`. Fee
growth wraps, so the gaps to `growth` are taken mod 2^256. -/
def mergeMark (heldMark movedMark held units growth : Nat) : Option Nat := do
  let heldGap := (growth + U256 - heldMark) % U256
  let movedGap := (growth + U256 - movedMark) % U256
  let total ← add256 held units
  let gap ← if heldGap ≤ movedGap then do pure (heldGap + (← mulDiv units (movedGap - heldGap) total))
    else do pure (heldGap - (← mulDivUp units (heldGap - movedGap) total))
  pure ((growth + U256 - gap) % U256)

/-- The seized units' pro-rata share of `owed`, rounded down (0 when `srcBal = 0` or `owed = 0`, all of `owed` when
`srcBal ≤ units`). -/
def moveOwed (owed srcBal units : Nat) : Option Nat :=
  if srcBal = 0 ∨ owed = 0 then some 0
  else if srcBal ≤ units then some owed
  else mulDiv owed units srcBal

/-- `seize`'s reward part (`RewardLedger._moveMarks`): `units` of `src`'s `srcBal` units move from `src` to `dst`,
who holds `held`, taking their bookmark and their pro-rata share of `src`'s credited `owed` (rounded down). -/
def moveMarks (L : Ledger) (src dst lp srcBal held units : Nat) : Option Ledger :=
  if src = dst ∨ units = 0 then some L else do
    let srcCp := L.checkpoints src lp
    let dstCp := L.checkpoints dst lp
    let mark ← mergeMark dstCp.growth srcCp.growth held units (L.growth lp)
    let moved ← moveOwed srcCp.owed srcBal units
    let dstOwed ← add256 dstCp.owed moved
    let cps₁ := setAt L.checkpoints src (setAt (L.checkpoints src) lp { srcCp with owed := srcCp.owed - moved })
    let cps₂ := setAt cps₁ dst (setAt (cps₁ dst) lp ⟨mark, dstOwed⟩)
    pure { L with checkpoints := cps₂ }

/-- `_payRewards` before the cut: the ledger after, and what it paid. -/
def pay (L : Ledger) (account lp : Nat) : Option (Ledger × Nat) :=
  let cp := L.checkpoints account lp
  let amount := min cp.owed (min (L.positionRewards lp) L.held)
  if amount = 0 then some (L, 0) else
    some ({ L with
      checkpoints := setAt L.checkpoints account (setAt (L.checkpoints account) lp { cp with owed := cp.owed - amount })
      positionRewards := setAt L.positionRewards lp (L.positionRewards lp - amount)
      held := L.held - amount }, amount)

inductive LedgerAction
  | book (lp arrived liquidity : Nat)
  | hold (amount : Nat)
  | checkpoint (account lp balance : Nat)
  | pay (account lp : Nat)
  | seize (src dst lp srcBal held units : Nat)
  deriving DecidableEq, Repr

/-- The position a step pays from (0 when it pays nothing). -/
def LedgerAction.paysFrom : LedgerAction → Nat
  | .pay _ lp => lp
  | _ => 0

/-- A reward ledger's steps, so `Spec` can state properties of any implementation and `Mutants` can show the
statements reject wrong ones. -/
structure Rewards where
  growth : Ledger → Nat → Nat → Option Nat
  book : Ledger → Nat → Nat → Nat → Option Ledger
  hold : Ledger → Nat → Option Ledger
  checkpoint : Ledger → Nat → Nat → Nat → Option Ledger
  pay : Ledger → Nat → Nat → Option (Ledger × Nat)
  seize : Ledger → Nat → Nat → Nat → Nat → Nat → Nat → Option Ledger

/-- Senzu's. -/
def senzuRewards : Rewards := ⟨rewardGrowth, book, hold, checkpoint, pay, moveMarks⟩

/-- One step: the ledger after, and what it paid (0 unless a payout). -/
def Rewards.step (r : Rewards) (L : Ledger) : LedgerAction → Option (Ledger × Nat)
  | .book lp a liq => do pure (← r.book L lp a liq, 0)
  | .hold x => do pure (← r.hold L x, 0)
  | .checkpoint acc lp b => do pure (← r.checkpoint L acc lp b, 0)
  | .pay acc lp => r.pay L acc lp
  | .seize src dst lp srcBal held units => do pure (← r.seize L src dst lp srcBal held units, 0)

/-- A sequence of steps: the ledger after, and what was paid from each position. -/
def Rewards.run (r : Rewards) (L : Ledger) : List LedgerAction → Option (Ledger × (Nat → Nat))
  | [] => pure (L, fun _ => 0)
  | act :: rest => do
    let (L₁, amount) ← r.step L act
    let (L₂, paid) ← r.run L₁ rest
    pure (L₂, fun l => if l = act.paysFrom then paid l + amount else paid l)

/-- What the steps booked as arrived for position `lp`. -/
def arrivedFor (lp : Nat) : List LedgerAction → Nat
  | [] => 0
  | .book l a _ :: rest => (if l = lp then a else 0) + arrivedFor lp rest
  | _ :: rest => arrivedFor lp rest

end Senzu
