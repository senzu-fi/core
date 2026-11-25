import Senzu.Evm

/-!
# Lending markets

`toShares`/`toAssets` are `MarketLogic`'s, `addDebt`/`repayAmounts`/`repay` are `BorrowLogic`'s, `writeOff` is
`SenzuBorrowable._writeOff`; the vectors compare all six with the Solidity, reverts included.

`Lending` names the conversion each call site makes, so `Spec` can state properties of any wiring and
`Mutants` can show the statements reject wrong ones. `Pool` and `LendAction` model the lender side as a state
machine. It allows more than the contract does (no zero-amount reverts, no `uint128` caps, a withdrawal is
limited by all assets rather than cash), so a safety property proved for it holds for the contract too.
-/

namespace Senzu

inductive Rounding
  | down
  | up
  deriving DecidableEq, Repr

def VIRTUAL_SHARES : Nat := 1000000
def VIRTUAL_ASSETS : Nat := 1

/-- `MarketLogic.toShares` -/
def toShares (assets totalAssets totalShares : Nat) (rounding : Rounding) : Option Nat := do
  let shares ← add256 totalShares VIRTUAL_SHARES
  let total ← add256 totalAssets VIRTUAL_ASSETS
  match rounding with
  | .up => mulDivUp assets shares total
  | .down => mulDiv assets shares total

/-- `MarketLogic.toAssets` -/
def toAssets (shares totalAssets totalShares : Nat) (rounding : Rounding) : Option Nat := do
  let total ← add256 totalAssets VIRTUAL_ASSETS
  let allShares ← add256 totalShares VIRTUAL_SHARES
  match rounding with
  | .up => mulDivUp shares total allShares
  | .down => mulDiv shares total allShares

/-- The accounting fields of `Market`. -/
structure Market where
  totalSupplyAssets : Nat
  totalBorrowAssets : Nat
  totalBorrowShares : Nat
  deriving DecidableEq, Repr

/-- `DebtLanes`: one position holds under 2^119 borrow shares in a market. -/
def MAX_POSITION_SHARES : Nat := 2 ^ 119 - 1

/-- `BorrowLogic.addDebt`'s borrow fee: its lender shares, and `totalSupplyAssets` after it. -/
def addFee (m : Market) (fee totalSupplyShares : Nat) : Option (Nat × Nat) :=
  if fee = 0 then some (0, m.totalSupplyAssets)
  else do
    let feeShares ← toShares fee m.totalSupplyAssets totalSupplyShares .down
    let supply ← add128 m.totalSupplyAssets (← toU128 fee)
    pure (feeShares, supply)

/-- `BorrowLogic.addDebt` for a position without debt in the market:
`(shares, feeShares, market after)`. -/
def addDebt (m : Market) (assets fee totalSupplyShares : Nat) : Option (Nat × Nat × Market) := do
  let cash ← sub m.totalSupplyAssets m.totalBorrowAssets
  require (assets ≤ cash)
  let debt ← add256 assets fee
  let (feeShares, supply) ← addFee m fee totalSupplyShares
  let shares ← toShares debt m.totalBorrowAssets m.totalBorrowShares .up
  let borrow ← add128 m.totalBorrowAssets (← toU128 debt)
  let borrowShares ← add128 m.totalBorrowShares (← toU128 shares)
  require (shares ≤ MAX_POSITION_SHARES)
  pure (shares, feeShares, ⟨supply, borrow, borrowShares⟩)

/-- The shares a payment of `x`, under the whole debt, burns (`BorrowLogic.repayAmounts`): those worth the whole wei
its shares (rounded down) are worth (rounded down), rounded up. None when it clears no whole wei. -/
def repayBurns (x a s : Nat) : Option Nat := do
  toShares (← toAssets (← toShares x a s .down) a s .down) a s .up

/-- `BorrowLogic.repayAmounts`: `(assets repaid, shares burned)`. -/
def repayAmounts (m : Market) (debtShares assets : Nat) : Option (Nat × Nat) := do
  require (debtShares ≠ 0)
  let debt ← toAssets debtShares m.totalBorrowAssets m.totalBorrowShares .up
  if debt ≤ assets then pure (debt, debtShares) else do
    require (assets ≠ 0)
    pure (assets, ← repayBurns assets m.totalBorrowAssets m.totalBorrowShares)

/-- `BorrowLogic.reduceDebt`. Its callers never take more than `totalBorrowAssets`; `Nat` subtraction stops at 0. -/
def reduceDebt (m : Market) (shares assets : Nat) : Option Market := do
  let borrowShares ← sub m.totalBorrowShares shares
  pure { m with totalBorrowShares := borrowShares, totalBorrowAssets := m.totalBorrowAssets - assets }

/-- What `BorrowLogic.repay` books for `shares`: all the debt for the last shares, else their worth rounded down. -/
def repayBooks (m : Market) (shares : Nat) : Option Nat :=
  if shares = m.totalBorrowShares then some m.totalBorrowAssets
  else toAssets shares m.totalBorrowAssets m.totalBorrowShares .down

/-- `BorrowLogic.repay`: the debt falls by what it books; lenders get the rest of `paid`. -/
def repay (m : Market) (shares paid : Nat) : Option Market := do
  let booked ← repayBooks m shares
  let total ← add256 m.totalSupplyAssets paid
  let supply ← sub total booked
  let supply ← toU128 supply
  let m' ← reduceDebt m shares booked
  pure { m' with totalSupplyAssets := supply }

/-- What `SenzuBorrowable._writeOff` takes from lenders for `shares` owing `debt`: all the market's debt for the last
shares, else the debt, at most the market's. -/
def writeOffLoss (m : Market) (shares debt : Nat) : Nat :=
  if shares = m.totalBorrowShares then m.totalBorrowAssets else min debt m.totalBorrowAssets

/-- `SenzuBorrowable._writeOff` on an accrued market: `(debt written off, market after)`. Lenders lose at most
`totalBorrowAssets`. -/
def writeOff (m : Market) (debtShares : Nat) : Option (Nat × Market) := do
  let debt ← toAssets debtShares m.totalBorrowAssets m.totalBorrowShares .up
  let loss := writeOffLoss m debtShares debt
  let m ← reduceDebt m debtShares loss
  pure (debt, { m with totalSupplyAssets := m.totalSupplyAssets - loss })

inductive MarketAction
  | supply (assets : Nat)
  | withdraw (assets : Nat)
  | borrow (assets fee totalSupplyShares : Nat)
  /-- A position holding `debtShares` repays up to `assets`. -/
  | repay (debtShares assets : Nat)
  /-- A position holding `debtShares` is written off. -/
  | writeOff (debtShares : Nat)
  | accrue (interest : Nat)
  deriving DecidableEq, Repr

/-- One action on a market's accounting, `writeOff` given so mutants can replace it. A position is any number
of shares up to the total. -/
def marketStep (wo : Market → Nat → Option (Nat × Market)) (m : Market) : MarketAction → Option Market
  | .supply x => pure { m with totalSupplyAssets := m.totalSupplyAssets + x }
  | .withdraw a => do
    let cash ← sub m.totalSupplyAssets m.totalBorrowAssets
    require (a ≤ cash)
    pure { m with totalSupplyAssets := m.totalSupplyAssets - a }
  | .borrow d fee supplyShares => do
    let r ← addDebt m d fee supplyShares
    pure r.2.2
  | .repay q x => do
    require (q ≤ m.totalBorrowShares)
    let r ← repayAmounts m q x
    repay m r.2 r.1
  | .writeOff q => do
    require (q ≤ m.totalBorrowShares)
    let r ← wo m q
    pure r.2
  | .accrue i => pure ⟨m.totalSupplyAssets + i, m.totalBorrowAssets + i, m.totalBorrowShares⟩

def marketRun (wo : Market → Nat → Option (Nat × Market)) (m : Market) : List MarketAction → Option Market
  | [] => pure m
  | act :: rest => do marketRun wo (← marketStep wo m act) rest

/-- The conversion each call site makes. Arguments: amount, total assets, total shares of the market side. -/
structure Lending where
  supplyShares : Nat → Nat → Nat → Option Nat
  withdrawAssets : Nat → Nat → Nat → Option Nat
  borrowShares : Nat → Nat → Nat → Option Nat
  debtOf : Nat → Nat → Nat → Option Nat
  repayShares : Nat → Nat → Nat → Option Nat

/-- Senzu's wiring. -/
def senzu : Lending where
  -- `BorrowablePositions.supply`; also the borrow fee's, the liquidation fee's and the reserve's shares
  supplyShares x a s := toShares x a s .down
  -- `BorrowablePositions.withdraw`
  withdrawAssets x a s := toAssets x a s .down
  -- `BorrowLogic.addDebt`
  borrowShares x a s := toShares x a s .up
  -- `BorrowLogic.repayAmounts`, `BorrowableModel`
  debtOf x a s := toAssets x a s .up
  -- `BorrowLogic.repayAmounts`, below the whole debt
  repayShares := repayBurns

/-- The lender side of a market: `totalSupplyAssets` and the lender shares' total supply. -/
structure Pool where
  assets : Nat
  shares : Nat
  deriving DecidableEq, Repr

inductive LendAction
  /-- A supply; the borrow fee, the liquidation fee and the reserve are supplies too. -/
  | supply (assets : Nat)
  | withdraw (shares : Nat)
  /-- Interest added to `totalSupplyAssets` (the part not minted to the reserve). -/
  | accrue (interest : Nat)
  deriving DecidableEq, Repr

/-- One action: the pool after it, and the assets it paid out (negative for a supply). -/
def Lending.step (l : Lending) (p : Pool) : LendAction → Option (Pool × Int)
  | .supply x => do
    let s ← l.supplyShares x p.assets p.shares
    pure (⟨p.assets + x, p.shares + s⟩, -(x : Int))
  | .withdraw s => do
    if p.shares < s then none
    let a ← l.withdrawAssets s p.assets p.shares
    if p.assets < a then none
    pure (⟨p.assets - a, p.shares - s⟩, (a : Int))
  | .accrue i => pure (⟨p.assets + i, p.shares⟩, 0)

/-- A sequence of actions: the pool after them, and the net assets paid out. -/
def Lending.run (l : Lending) (p : Pool) : List LendAction → Option (Pool × Int)
  | [] => pure (p, 0)
  | act :: rest => do
    let (p₁, out₁) ← l.step p act
    let (p₂, out₂) ← l.run p₁ rest
    pure (p₂, out₁ + out₂)

/-- Interest added by a sequence of actions. -/
def interestOf : List LendAction → Nat
  | [] => 0
  | .accrue i :: rest => i + interestOf rest
  | _ :: rest => interestOf rest

end Senzu
