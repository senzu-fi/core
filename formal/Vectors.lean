import Senzu.Fees
import Senzu.Liquidation
import Senzu.Rewards
import Senzu.Range

/-!
Replays the Solidity's vectors (`script/SdkVectors.s.sol`) through the
model and fails on any difference, reverts included.
-/

open Senzu

def show? : Option Nat → String
  | some n => toString n
  | none => "err"

def shares : List Nat → Option String
  | [amount, assets, totalShares, up] =>
    let r : Rounding := if up = 1 then .up else .down
    some s!"{show? (toShares amount assets totalShares r)} {show? (toAssets amount assets totalShares r)}"
  | _ => none

def borrow : List Nat → Option String
  | [supply, borrow, borrowShares, assets, fee, supplyShares] =>
    some <| match addDebt ⟨supply, borrow, borrowShares⟩ assets fee supplyShares with
      | some (s, f, m) => s!"{s} {f} {m.totalSupplyAssets} {m.totalBorrowAssets} {m.totalBorrowShares}"
      | none => "err"
  | _ => none

def repay : List Nat → Option String
  | [borrow, borrowShares, debtShares, assets] =>
    some <| match repayAmounts ⟨0, borrow, borrowShares⟩ debtShares assets with
      | some (repaid, burned) => s!"{repaid} {burned}"
      | none => "err"
  | _ => none

/-- The whole position is written off, so the contract's position shares after must be 0. -/
def writeOffLine : List Nat → Option String
  | [supply, borrow, borrowShares, debtShares] =>
    some <| match writeOff ⟨supply, borrow, borrowShares⟩ debtShares with
      | some (_, m) => s!"{m.totalSupplyAssets} {m.totalBorrowAssets} {m.totalBorrowShares} 0"
      | none => "err"
  | _ => none

/-- `SenzuBorrowable._bookRepay` on an accrued market: what it takes, the market after and the shares left. -/
def repayBookLine : List Nat → Option String
  | [supply, borrow, borrowShares, debtShares, assets] =>
    let m : Market := ⟨supply, borrow, borrowShares⟩
    some <| match (do
        let r ← repayAmounts m debtShares assets
        let m' ← repay m r.2 r.1
        pure (r, m')) with
      | some (r, m') =>
        s!"{r.1} {m'.totalSupplyAssets} {m'.totalBorrowAssets} {m'.totalBorrowShares} {debtShares - r.2}"
      | none => "err"
  | _ => none

def ledgerAction : List Nat → Option LedgerAction
  | [0, lp, arrived, liquidity, _, _, _] => some (.book lp arrived liquidity)
  | [1, amount, _, _, _, _, _] => some (.hold amount)
  | [2, account, lp, balance, _, _, _] => some (.checkpoint account lp balance)
  | [3, account, lp, _, _, _, _] => some (.pay account lp)
  | [4, src, dst, lp, srcBal, held, units] => some (.seize src dst lp srcBal held units)
  | _ => none

def ledgerState (L : Ledger) : List String :=
  ([1, 2].flatMap fun lp => [L.growth lp, L.positionRewards lp]) ++ [L.held] ++
    ([1, 2, 3].flatMap fun a => [1, 2].flatMap fun lp =>
      let cp := L.checkpoints a lp
      [cp.growth, cp.owed]) |>.map toString

/-- Each step's result ("-", what a payout paid, "err" ending it), then the ledger's state. -/
def rewardLedgerLine : List Nat → Option String
  | n :: rest => do
    let acts ← (List.range n).mapM fun i => ledgerAction ((rest.drop (7 * i)).take 7)
    let rec go (L : Ledger) : List LedgerAction → List String
      | [] => "|" :: ledgerState L
      | act :: more => match senzuRewards.step L act with
        | some (L', paid) => (match act with | .pay _ _ => toString paid | _ => "-") :: go L' more
        | none => ["err"]
    pure (" ".intercalate (go Ledger.empty acts))
  | [] => none

/-- Accounts 1, 2, 3 of the vectors. -/
def feeAccount (a : Nat) : Option (Fin 3) := if h : 1 ≤ a ∧ a ≤ 3 then some ⟨a - 1, by omega⟩ else none

def feeAction : List Nat → Option (FeeModel.FeeAction (Fin 3))
  | [0, amount, _, _] => some (.accrue amount)
  | [1, a, n, _] => do pure (.mint (← feeAccount a) n)
  | [2, a, n, _] => do pure (.burn (← feeAccount a) n)
  | [3, a, _, _] => do pure (.collect (← feeAccount a))
  | [4, a, b, n] => do pure (.seize (← feeAccount a) (← feeAccount b) n)
  | _ => none

def feeState (s : FeeModel.FeeState (Fin 3)) : List String :=
  ([s.growth, s.held, s.pending] ++ [0, 1, 2].flatMap fun (i : Fin 3) => [s.units i, s.mark i, s.owed i]).map toString

/-- Each step's result ("-", what a collect paid, "err" ending it), then the ledger's state. -/
def feeLedgerLine : List Nat → Option String
  | n :: rest => do
    let acts ← (List.range n).mapM fun i => feeAction ((rest.drop (4 * i)).take 4)
    let rec go (s : FeeModel.FeeState (Fin 3)) : List (FeeModel.FeeAction (Fin 3)) → List String
      | [] => "|" :: feeState s
      | act :: more => match (FeeModel.senzuFees (Fin 3)).step s act with
        | some (s', paid) => (match act with | .collect _ => toString paid | _ => "-") :: go s' more
        | none => ["err"]
    pure (" ".intercalate (go (FeeModel.FeeState.empty _) acts))
  | [] => none

/-- `fields`: compare only the first outputs, for files with outputs the model leaves out. -/
def replay (dir : System.FilePath) (name : String) (model : List Nat → Option String) (fields : Option Nat := none) :
    IO Bool := do
  let mut rows := 0
  let mut failed := 0
  for line in ← IO.FS.lines (dir / s!"{name}.txt") do
    if line.startsWith "#" || line.trimAscii.isEmpty then continue
    let [lhs, rhs] := line.splitOn " => " | throw <| IO.userError s!"{name}: unreadable line {line}"
    let rhs := rhs.trimAscii.toString
    let rhs := " ".intercalate ((rhs.splitOn " ").map fun t => if t.startsWith "err:" then "err" else t)
    let rhs := match fields with
      | some n => " ".intercalate ((rhs.splitOn " ").take n)
      | none => rhs
    let inputs := (lhs.splitOn " ").filter (· ≠ "") |>.map String.toNat!
    let some got := model inputs | throw <| IO.userError s!"{name}: unexpected inputs {line}"
    rows := rows + 1
    if got != rhs then
      failed := failed + 1
      if failed ≤ 5 then IO.eprintln s!"{name}: {lhs}\n  solidity: {rhs}\n  model:    {got}"
  IO.println s!"{name}: {rows - failed}/{rows}"
  return rows > 0 && failed == 0

def mergeMarkLine : List Nat → Option String
  | [heldMark, movedMark, held, units, growth] => some (show? (mergeMark heldMark movedMark held units growth))
  | _ => none

def seizeLine : List Nat → Option String
  | [collateralUsd, debtUsd, debt, price, decimals, penalty, maxRepay, units] =>
    -- `10 ** decimals` overflows past 77
    let unit := 10 ^ decimals
    some <| if U256 ≤ unit then "err" else
      match senzuLiquidation.liquidate collateralUsd debtUsd debt price unit penalty maxRepay units with
      | some (seized, paid) => s!"{seized} {paid}"
      | none => "err"
  | _ => none

def seizeFeeLine : List Nat → Option String
  | [collateralUsd, debtUsd, debt, price, decimals, penalty, maxRepay, units, feeWad, other] =>
    let unit := 10 ^ decimals
    some <| if U256 ≤ unit then "err" else
      match senzuLiquidation.liquidateWithFee liquidationFee collateralUsd debtUsd debt price unit penalty maxRepay
          units feeWad (other == 1) with
      | some (seized, paid, fee) => s!"{seized} {paid} {fee}"
      | none => "err"
  | _ => none

def amountDeltaLine : List Nat → Option String
  | [a, b, liquidity, up] =>
    let r : Rounding := if up = 1 then .up else .down
    some s!"{show? (amount0Delta a b liquidity r)} {show? (amount1Delta a b liquidity r)}"
  | _ => none

/-- `getAmountsForLiquidity` only: the file's last output, `liquidityFor`, isn't modeled. -/
def liquidityAmountsLine : List Nat → Option String
  | [s, a, b, liquidity, _, _] =>
    some <| match amountsForLiquidity s a b liquidity with
      | some (x, y) => s!"{x} {y}"
      | none => "err err"
  | _ => none

/-- `FixedPointMathLib.sqrt` is the floor of the root. -/
def sqrtLine : List Nat → Option String
  | [x] => some (toString (Nat.sqrt x))
  | _ => none

/-- `HealthMath.sqrtPriceX96FromUsd`: `_sqrtPriceX96Scaled` at 10^decimals (which overflows past 77). -/
def sqrtPriceFromUsdLine : List Nat → Option String
  | [p0, p1, d0, d1] =>
    some <| if U256 ≤ 10 ^ d0 ∨ U256 ≤ 10 ^ d1 then "err" else show? (sqrtPriceX96Scaled p0 p1 (10 ^ d0) (10 ^ d1))
  | _ => none

def main (args : List String) : IO UInt32 := do
  let dir : System.FilePath := args.headD "vectors"
  let mut ok := true
  for (name, model) in [("shares", shares), ("borrow", borrow), ("repay", repay), ("write_off", writeOffLine),
      ("repay_book", repayBookLine), ("reward_ledger", rewardLedgerLine), ("seize", seizeLine),
      ("seize_fee", seizeFeeLine), ("merge_mark", mergeMarkLine), ("fee_ledger", feeLedgerLine)] do
    ok := (← replay dir name model) && ok
  ok := (← replay dir "amount_delta" amountDeltaLine) && ok
  ok := (← replay dir "liquidity_amounts" liquidityAmountsLine (fields := some 2)) && ok
  ok := (← replay dir "sqrt" sqrtLine) && ok
  ok := (← replay dir "sqrt_price_from_usd" sqrtPriceFromUsdLine) && ok
  return if ok then 0 else 1
