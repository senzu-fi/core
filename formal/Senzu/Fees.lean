import Mathlib.Algebra.BigOperators.Group.Finset.Basic
import Senzu.Rewards

/-!
# The fee ledger

`FeeLedger` and `HeldFeesAdapter` for one position and one token, over any finite set of accounts `A`: a
position's two tokens and every position have their own storage and the same code, so one of each is the whole
ledger. `pending` is the DEX's side: fees it earned for the position and hasn't paid the adapter yet. The steps
are what the core and holders can do:

- `accrue`: the DEX earns fees for the position (it holds liquidity, so it has units).
- `mint` / `burn`: `increaseLiquidity` / `decreaseLiquidity`: poke (`_collectPending`, booked by `_bookFees`),
  checkpoint the account, change its units.
- `collect`: `collectFees`: poke and checkpoint a holder (nothing for an account with no units), then pay what it is
  owed (`_payFeesOwed` before the protocol's cut, `_sendFees`).
- `seize`: `seize` (`_moveMarks`) then the core's unit move: the seized units take a bookmark merged at the
  preview (`_previewGrowth`) and their share of the source's credited `owed`. Nothing is poked or paid.

The vectors (`fee_ledger`) compare it with the Solidity over random sequences of steps, reverts included.
-/

namespace Senzu.FeeModel

open Finset

/-- One position's fee storage for one token, and the DEX's unpaid fees for it. -/
structure FeeState (A : Type) where
  /-- The collateral's `balanceOf(account, lpId)` -/
  units : A → ℕ
  /-- `checkpoints[account][lpId].feeGrowthInside0X128` -/
  mark : A → ℕ
  /-- `checkpoints[account][lpId].owed0` -/
  owed : A → ℕ
  /-- `fees[lpId].growth0X128` -/
  growth : ℕ
  /-- `fees[lpId].held0` -/
  held : ℕ
  /-- What the DEX owes the position and hasn't paid -/
  pending : ℕ

/-- A new position: every slot 0. -/
def FeeState.empty (A : Type) : FeeState A := ⟨fun _ => 0, fun _ => 0, fun _ => 0, 0, 0, 0⟩

variable {A : Type} [Fintype A] [DecidableEq A]

/-- The position's units: `totalSupply(lpId)`, the liquidity `_bookFees` divides by. -/
def FeeState.total (s : FeeState A) : ℕ := ∑ a, s.units a

/-- `_previewGrowth`: the booked growth plus what the DEX owes, per unit. -/
def preview (s : FeeState A) : Option ℕ :=
  if s.total = 0 then some s.growth else do
    let x ← mulDiv s.pending Q128 s.total
    add256 s.growth x

/-- `_pokeGrowth`: the DEX pays what it owes and `_bookFees` books it (`held0 += fee.toUint128()`, then the growth). -/
def poke (s : FeeState A) : Option (FeeState A) :=
  if s.pending = 0 then some s else do
    let held ← add128 s.held s.pending
    let x ← mulDiv s.pending Q128 s.total
    let growth ← add256 s.growth x
    pure { s with held, growth, pending := 0 }

/-- `FeeLogic.checkpoint` at the booked growth: credits the units' growth since the bookmark (`owed0` stays a
`uint128`), then moves the bookmark. -/
def checkpoint (s : FeeState A) (a : A) : Option (FeeState A) := do
  let owed ← if s.units a = 0 then some (s.owed a) else do
    let gained ← mulDiv (s.units a) ((s.growth + U256 - s.mark a) % U256) Q128
    let o ← add256 (s.owed a) gained
    toU128 o
  pure { s with owed := Function.update s.owed a owed, mark := Function.update s.mark a s.growth }

/-- `_payFeesOwed` before the cut: pays the account everything it is owed out of what the position holds. -/
def pay (s : FeeState A) (a : A) : Option (FeeState A × ℕ) := do
  let held ← sub s.held (s.owed a)
  pure ({ s with held, owed := Function.update s.owed a 0 }, s.owed a)

/-- `_moveMarks` and the core's unit move: `n` of `src`'s units go to `dst` with a bookmark merged at the preview and
their share of `src`'s credited `owed` (all of it when all the units go), rounded down. -/
def seize (s : FeeState A) (src dst : A) (n : ℕ) : Option (FeeState A) :=
  if src = dst ∨ n = 0 then some s else do
    let units ← sub (s.units src) n
    let g ← preview s
    let mark ← mergeMark (s.mark dst) (s.mark src) (s.units dst) n g
    let moved ← if s.units src = 0 ∨ s.owed src = 0 then some 0
      else if s.units src ≤ n then some (s.owed src)
      else mulDiv (s.owed src) n (s.units src)
    let dstOwed ← add128 (s.owed dst) moved
    let owed := Function.update (Function.update s.owed src (s.owed src - moved)) dst dstOwed
    pure { s with
      mark := Function.update s.mark dst mark, owed,
      units := Function.update (Function.update s.units src units) dst (s.units dst + n) }

inductive FeeAction (A : Type)
  | accrue (amount : ℕ)
  | mint (account : A) (n : ℕ)
  | burn (account : A) (n : ℕ)
  | collect (account : A)
  | seize (src dst : A) (n : ℕ)

/-- A fee ledger's steps, so `Spec` can state properties of any implementation and `Mutants` can show the
statements reject wrong ones. -/
structure Fees (A : Type) where
  poke : FeeState A → Option (FeeState A)
  checkpoint : FeeState A → A → Option (FeeState A)
  pay : FeeState A → A → Option (FeeState A × ℕ)
  seize : FeeState A → A → A → ℕ → Option (FeeState A)

/-- Senzu's. -/
def senzuFees (A : Type) [Fintype A] [DecidableEq A] : Fees A := ⟨poke, checkpoint, pay, seize⟩

/-- One step: the state after, and what it paid. -/
def Fees.step (f : Fees A) (s : FeeState A) : FeeAction A → Option (FeeState A × ℕ)
  | .accrue x => if s.total = 0 then none else some ({ s with pending := s.pending + x }, 0)
  | .mint a n => do
    let s₁ ← f.poke s
    let s₂ ← f.checkpoint s₁ a
    pure ({ s₂ with units := Function.update s₂.units a (s₂.units a + n) }, 0)
  | .burn a n => do
    let s₁ ← f.poke s
    let s₂ ← f.checkpoint s₁ a
    let u ← sub (s₂.units a) n
    pure ({ s₂ with units := Function.update s₂.units a u }, 0)
  | .collect a => do
    let s₁ ← if s.units a = 0 then some s else do f.checkpoint (← f.poke s) a
    f.pay s₁ a
  | .seize src dst n => do pure (← f.seize s src dst n, 0)

/-- A sequence of steps: the state after, and everything it paid. -/
def Fees.run (f : Fees A) (s : FeeState A) : List (FeeAction A) → Option (FeeState A × ℕ)
  | [] => pure (s, 0)
  | act :: rest => do
    let (s₁, amount) ← f.step s act
    let (s₂, paid) ← f.run s₁ rest
    pure (s₂, amount + paid)

/-- What `a` could collect if the DEX paid now, at the preview `P`, unrounded and in growth units (×2^128): its
credited fees plus its units' growth since its bookmark. -/
def claimAt (s : FeeState A) (P : ℕ) (a : A) : ℕ := s.owed a * Q128 + s.units a * (P - s.mark a)

/-- What the DEX earned for the position over the steps. -/
def earned : List (FeeAction A) → ℕ
  | [] => 0
  | .accrue x :: rest => x + earned rest
  | _ :: rest => earned rest

end Senzu.FeeModel
