#!/usr/bin/env bash
# Each mutation of the model must make the vectors fail; one that doesn't shows a case the vectors don't cover.
set -euo pipefail
cd "$(dirname "$0")/.."

models=(Senzu/Market.lean Senzu/Rewards.lean Senzu/Fees.lean Senzu/Liquidation.lean Senzu/Range.lean)
backup=$(mktemp -d)
cp "${models[@]}" "$backup"
restore() { for f in "${models[@]}"; do cp "$backup/$(basename "$f")" "$f"; done; }
trap 'restore; rm -rf "$backup"; lake build vectors -q >/dev/null' EXIT

# Since 2026-11-20 (audit M-03, H-01) a write-off's loss and a repayment's booking never pass the market's debt, and
# M1 keeps that under supply, so whether supply or borrows stop at 0 or revert is unreachable: no mutation for it
# `liquidate`'s first two requires have no mutation: without them a zero collateral or debt still reverts later (a
# division by zero, or the zero repayment)
# `amountsForLiquidity`'s range bounds have no mutation: at s = lower or s = upper both branches give the same
# amounts (the other token's is L·0), so moving a bound changes nothing
# A seize to oneself has no mutation: merging a bookmark with itself gives the same bookmark
# The fee checkpoint's zero-units shortcut has no mutation: with no units the gain is 0 either way. Nor its
# `toU128`: FL1 keeps everything owed under what's held, which is under 2^128. Nor a full seize's "move all the
# owed": `owed · n / n` is `owed`, and a seize of more than the balance reverts first. Nor the growth a fee seize
# merges at (the preview, or the booked growth, or either rounded): at any growth at or above both bookmarks the
# merge gives the same bookmark, since both gaps move by the same amount and only their difference is split, and
# the booked growth is already at or above every bookmark (`FeeInv`)
mutations=(
  "toShares rounds up as down~| .up => mulDivUp assets shares total~| .up => mulDiv assets shares total"
  "toAssets rounds down as up~| .down => mulDiv shares total allShares~| .down => mulDivUp shares total allShares"
  "no virtual shares~def VIRTUAL_SHARES : Nat := 1000000~def VIRTUAL_SHARES : Nat := 1"
  "borrow fee shares round up~toShares fee m.totalSupplyAssets totalSupplyShares .down~toShares fee m.totalSupplyAssets totalSupplyShares .up"
  "borrow shares round down~toShares debt m.totalBorrowAssets m.totalBorrowShares .up~toShares debt m.totalBorrowAssets m.totalBorrowShares .down"
  "repay of exactly the debt takes the partial path~if debt ≤ assets then~if debt < assets then"
  "repay burns the shares it buys (the rule before 2026-11-21)~toShares (← toAssets (← toShares x a s .down) a s .down) a s .up~toShares x a s .down"
  "repay buys shares rounded up~(← toShares x a s .down) a s .down) a s .up~(← toShares x a s .up) a s .down) a s .up"
  "repay clears the wei rounded up~(← toShares x a s .down) a s .down) a s .up~(← toShares x a s .down) a s .up) a s .up"
  "repay burns the cleared wei's shares rounded down~(← toShares x a s .down) a s .down) a s .up~(← toShares x a s .down) a s .down) a s .down"
  "repay of 0 accepted~    require (assets ≠ 0)~    require True"
  "no cash check~require (assets ≤ cash)~require True"
  "repay books its shares rounded up~else toAssets shares m.totalBorrowAssets m.totalBorrowShares .down~else toAssets shares m.totalBorrowAssets m.totalBorrowShares .up"
  "the last shares book only their worth~if shares = m.totalBorrowShares then some~if shares = m.totalBorrowShares + 1 then some"
  "repay keeps what it paid over the shares' worth~let total ← add256 m.totalSupplyAssets paid~let total ← add256 m.totalSupplyAssets booked"
  "write-off rounds down~m.totalBorrowShares .up\\n  let loss~m.totalBorrowShares .down\\n  let loss"
  "write-off loss passes the market's debt~else min debt m.totalBorrowAssets~else debt"
  "the last shares' write-off takes only their debt~if shares = m.totalBorrowShares then m.totalBorrowAssets~if shares = m.totalBorrowShares + 1 then m.totalBorrowAssets"
  "write-off forgets supply~pure (debt, { m with totalSupplyAssets := m.totalSupplyAssets - loss })~pure (debt, m)"
  "a booking's growth rounds up~let x ← mulDiv arrived Q128 liquidity~let x ← mulDivUp arrived Q128 liquidity"
  "a booking sets the growth instead of adding to it~let growth ← add256 (L.growth lp) x~let growth ← some x"
  "a checkpoint's gain rounds up~let gained ← mulDiv balance dg Q128~let gained ← mulDivUp balance dg Q128"
  "a checkpoint forgets what was owed~  add256 cp.owed gained~  some gained"
  "a checkpoint keeps its old growth~setAt (L.checkpoints account) lp ⟨g, o⟩) }~setAt (L.checkpoints account) lp ⟨(L.checkpoints account lp).growth, o⟩) }"
  "a payout isn't capped by the position's rewards~min cp.owed (min (L.positionRewards lp) L.held)~min cp.owed L.held"
  "a payout isn't capped by what's held~min cp.owed (min (L.positionRewards lp) L.held)~min cp.owed (L.positionRewards lp)"
  "a booking doesn't count what arrived for the position~add256 (L.positionRewards lp) arrived~add256 (L.positionRewards lp) 0"
  "a seize's merge rounds up toward the borrower's bookmark~pure (heldGap + (← mulDiv units~pure (heldGap + (← mulDivUp units"
  "a seize's merge rounds down away from the liquidator's~pure (heldGap - (← mulDivUp units~pure (heldGap - (← mulDiv units"
  "a seize's units wrap~let total ← add256 held units~let total ← some ((held + units) % U256)"
  "a seize keeps the liquidator's bookmark~setAt (cps₁ dst) lp ⟨mark, dstOwed⟩~setAt (cps₁ dst) lp ⟨dstCp.growth, dstOwed⟩"
  "a seize takes the borrower's bookmark~setAt (cps₁ dst) lp ⟨mark, dstOwed⟩~setAt (cps₁ dst) lp ⟨srcCp.growth, dstOwed⟩"
  "a seize forgets to move credited owed~else mulDiv owed units srcBal~else some 0"
  "a seize rounds moved owed up~else mulDiv owed units srcBal~else mulDivUp owed units srcBal"
  "a seize doesn't debit source's credited owed~{ srcCp with owed := srcCp.owed - moved }~srcCp"
  "a seize doesn't credit receiver's owed~let dstOwed ← add256 dstCp.owed moved~let dstOwed ← some dstCp.owed"
  "a seize of no units isn't skipped~if src = dst ∨ units = 0 then some L~if src = dst then some L"
  "a poke's growth rounds up~    let x ← mulDiv s.pending Q128 s.total\n    let growth~    let x ← mulDivUp s.pending Q128 s.total\n    let growth"
  "a poke books the DEX's fees without collecting them~pure { s with held, growth, pending := 0 }~pure { s with held, growth }"
  "a poke doesn't count what it collected as held~let held ← add128 s.held s.pending~let held ← some s.held"
  "a fee checkpoint's gain rounds up~let gained ← mulDiv (s.units a) ((~let gained ← mulDivUp (s.units a) (("
  "a fee checkpoint forgets what was owed~let o ← add256 (s.owed a) gained~let o ← some gained"
  "a fee checkpoint keeps its old bookmark~mark := Function.update s.mark a s.growth }~mark := s.mark }"
  "a collect doesn't take what it paid from what's held~let held ← sub s.held (s.owed a)~let held ← some s.held"
  "a collect doesn't clear what it paid~pure ({ s with held, owed := Function.update s.owed a 0 }, s.owed a)~pure ({ s with held }, s.owed a)"
  "a collect with no units pokes and checkpoints~let s₁ ← if s.units a = 0 then some s else do f.checkpoint (← f.poke s) a~let s₁ ← f.checkpoint (← f.poke s) a"
  "an accrual with no units doesn't revert~| .accrue x => if s.total = 0 then none else~| .accrue x => if False then none else"
  "a fee seize forgets to move credited owed~else mulDiv (s.owed src) n (s.units src)~else some 0"
  "a fee seize rounds moved owed up~else mulDiv (s.owed src) n (s.units src)~else mulDivUp (s.owed src) n (s.units src)"
  "a fee seize keeps the receiver's bookmark~mark := Function.update s.mark dst mark, owed,~mark := s.mark, owed,"
  "a fee seize of no units isn't skipped~if src = dst ∨ n = 0 then some s else do~if src = dst then some s else do"
  "a liquidation of nothing doesn't revert~require (repay ≠ 0)~require True"
  "taking every unit only past the collateral~if collateralUsd ≤ withPenalty then do~if collateralUsd < withPenalty then do"
  "a liquidation repays the whole debt, not the offer~let repay := min maxRepay debt~let repay := debt"
  "the penalty isn't shrunk to what the position bears~pure (if ratio ≥ penalty then penalty else~pure (if True then penalty else"
  "the shrunk penalty has no floor~if ratio < MIN_INCENTIVE then MIN_INCENTIVE else ratio~if False then MIN_INCENTIVE else ratio"
  "a debt-free position bears MIN_INCENTIVE~if debtUsd = 0 then some penalty~if debtUsd = 0 then some MIN_INCENTIVE"
  "the repayment's USD rounds up~let repayUsd ← mulDiv repay price unit~let repayUsd ← mulDivUp repay price unit"
  "the penalty rounds up~let withPenalty ← mulDiv repayUsd penalty WAD~let withPenalty ← mulDivUp repayUsd penalty WAD"
  "the units seized round up~let seized ← mulDiv units withPenalty collateralUsd~let seized ← mulDivUp units withPenalty collateralUsd"
  "no cap up to twice the collateral (the dust gap before 2026-11-23, wider)~if collateralUsd ≤ withPenalty then do~if collateralUsd + collateralUsd ≤ withPenalty then do"
  "the collateral at MIN_INCENTIVE rounds down~let atMin ← mulDivUp collateralUsd WAD MIN_INCENTIVE~let atMin ← mulDiv collateralUsd WAD MIN_INCENTIVE"
  "what it covers rounds down~let coverable ← mulDivUp atMin unit price~let coverable ← mulDiv atMin unit price"
  "taking every unit repays the cover, even above the offer~pure (units, if coverable < repay then coverable else repay)~pure (units, coverable)"
  "the fee has no bad-debt floor~if atFloor < D ∨ (seized~if False ∨ (seized"
  "the fee's floor rounds up~let atFloor ← mulDiv C WAD MIN_INCENTIVE~let atFloor ← mulDivUp C WAD MIN_INCENTIVE"
  "the fee forgets another debt~(repaid < d ∨ other = true)~(repaid < d)"
  "the fee is charged when this debt is written off~(seized = U ∧ (repaid < d ∨~(seized = U ∧ (False ∨"
  "the fee on everything seized, not the gain~mulDiv (seizedAssets - repaid) feeWad WAD~mulDiv seizedAssets feeWad WAD"
  "the fee rounds up~mulDiv (seizedAssets - repaid) feeWad WAD~mulDivUp (seizedAssets - repaid) feeWad WAD"
  "the seized worth rounds up~let seizedUsd ← mulDiv C seized U~let seizedUsd ← mulDivUp C seized U"
  "the seized worth in the asset rounds up~let seizedAssets ← mulDiv seizedUsd unit price~let seizedAssets ← mulDivUp seizedUsd unit price"
  "the fee feeds back into the repayment~pure (seized, repaid, f)~pure (seized, repaid + f, f)"
  "amount0 rounded down rounds up~| .down => pure ((← mulDiv (L * Q96)~| .down => pure ((← mulDivUp (L * Q96)"
  "amount0 rounded up skips the second ceiling~+ lo - 1) / lo)~) / lo)"
  "amount1 rounded down rounds up~| .down => mulDiv L (max a b - min a b) Q96~| .down => mulDivUp L (max a b - min a b) Q96"
  "a zero lower √price doesn't revert~require (lo ≠ 0)~require True"
  "the √price keeps 64 bits below 2^64 (the root before 2026-11-21)~then (mulDiv n (2 ^ 192) d).map (fun x => clampSqrt (Nat.sqrt x))~then (mulDiv n (2 ^ 128) d).map (fun x => clampSqrt (Nat.sqrt x * 2 ^ 32))"
  "the 96-bit root stops at 2^63~else if n / d < 2 ^ 64 then~else if n / d < 2 ^ 63 then"
  "no top √price from 2^128~if d = 0 ∨ 2 ^ 128 ≤ n / d then~if d = 0 then"
  "no clamp~def clampSqrt (r : Nat) : Nat := max MIN_SQRT_PRICE (min r MAX_SQRT_PRICE)~def clampSqrt (r : Nat) : Nat := r"
  "position share cap 2^120~def MAX_POSITION_SHARES : Nat := 2 ^ 119 - 1~def MAX_POSITION_SHARES : Nat := 2 ^ 120 - 1"
)

survived=0
for m in "${mutations[@]}"; do
  IFS='~' read -r label old new <<<"$m"
  restore
  python3 -I - "$old" "$new" "${models[@]}" <<'PY'
import sys
old, new = (a.replace("\\n", "\n") for a in sys.argv[1:3])
hits = [p for p in sys.argv[3:] if old in open(p).read()]
assert len(hits) == 1 and open(hits[0]).read().count(old) == 1, f"mutation target not found exactly once: {old}"
src = open(hits[0]).read()
open(hits[0], "w").write(src.replace(old, new))
PY
  lake build vectors -q >/dev/null
  if lake exe vectors >/dev/null 2>&1; then
    echo "SURVIVED: $label"
    survived=$((survived + 1))
  else
    echo "killed:   $label"
  fi
done
exit "$survived"
