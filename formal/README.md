# Senzu formal

Lean 4 proofs about a model of Senzu's core math. Lean's kernel checks the proofs; everything else here checks
that they mean something: the statements are frozen and reviewed, each one rejects a known-wrong wiring, each
one's hypotheses can hold, and the model matches the Solidity on its vectors.

## Layout

- `Senzu/Evm.lean`: `uint256` arithmetic, `none` is a revert (`fullMulDiv`, checked adds, casts).
- `Senzu/Market.lean`: the model. `MarketLogic.toShares`/`toAssets`, `BorrowLogic.addDebt`/`repayAmounts`/`repay`,
  `SenzuBorrowable._writeOff`, the rounding each call site uses (`senzu`), and the lender side as a state machine.
- `Senzu/Rewards.lean`: `RewardLedger`'s five steps (`book`, `hold`, `checkpoint`, `pay`, and a seize's
  `moveMarks` with `FeeLogic.mergeMark`) over any arguments, as `senzuRewards`, and a sequence of them.
- `Senzu/Fees.lean`: `FeeLedger` and `HeldFeesAdapter` for one position and one token over any finite set of
  accounts: the DEX's unpaid fees (`pending`), `poke` (`_collectPending` and `_bookFees`), `checkpoint`, `pay`
  (`_payFeesOwed` before the cut) and `seize` (`_moveMarks` and the core's unit move), as `senzuFees`, and a sequence
  of accruals, mints, burns, collects and seizes.
- `Senzu/Liquidation.lean`: `LiquidationLogic.seizeFor` (`bearable`, `seize`) from the health check's numbers, as
  `senzuLiquidation`, and its protocol fee from the seize's result (`liquidationFee`).
- `Senzu/Range.lean`: what a range position holds, as every adapter's `amountsAt` computes it (`RangeAmounts.at`,
  `liquidityOf`, Uniswap's `getAmountsForLiquidity`), and the same in ℝ without rounding; the four-corner check
  in ℝ, as `fourCorners`.
- `Senzu/Spec.lean`: the statements, no proofs. Locked by `Spec.lock`.
- `Senzu/Mutants.lean`: wrong wirings, each refuted by a statement with concrete numbers.
- `Senzu/Witness.lean`: cases where each statement's hypotheses hold for `senzu`.
- `Senzu/Proofs/`: the proofs. `Model.lean` unpacks what a successful step did; `Conversions`, `Lenders`,
  `Borrowers`, `BadDebt`, `Repayments`, `Rewards`, `Fees`, `Liquidation`, `Fee`, `Health` and `Range` prove the statements.
- `Senzu/Check.lean`: each statement in `Spec.lean`, applied to Senzu's wiring, bound to its proof.
- `Vectors.lean`: replays the vectors in `vectors/`, which `script/SdkVectors.s.sol` writes (`shares`, `borrow`,
  `repay`; `write_off` and `repay_book`, through `script/sdk/WriteOffHarness.sol`; `reward_ledger`, random sequences
  of the ledger's steps through `script/sdk/RewardLedgerHarness.sol`; `fee_ledger`, random sequences of the fee
  ledger's steps through `script/sdk/FeeLedgerHarness.sol`; `merge_mark`, `FeeLogic.mergeMark`; `seize`,
  `LiquidationLogic.seizeFor`; `seize_fee`, the same with the protocol fee; `amount_delta` and `liquidity_amounts`,
  Uniswap's amount math).
- `ASSUMPTIONS.md`: what the model leaves out and what is trusted.
- `quint/lock.qnt`: a Quint model of `lock()`: deferred health checks, seize-first liquidations, settle and
  write-offs, over two debt assets, with the borrow fee and the liquidation fee to reserves. Apalache proves its
  properties at every depth (an inductive invariant); each `CHECK_*` switch turned off must break the proof.

## Commands

Needs elan (`~/.elan/bin`); the first build downloads Mathlib's cache (`lake exe cache get`). The Quint steps need
`quint` 0.33.1 on the PATH (`npm i -g @informalsystems/quint@0.33.1`) and Java for Apalache.

```
cd formal && scripts/check.sh     # everything below, in order
lake build --wfail                # proofs, mutants, witnesses
lake env lean scripts/Axioms.lean # every declaration uses only propext, Classical.choice, Quot.sound
lake exe vectors                  # the model against the Solidity, reverts included
scripts/mutate-model.sh           # each model mutation must fail the vectors
(cd quint && quint verify lock.qnt --inductive-invariant=inductive --invariant=safe)   # the lock model, ~3 min
scripts/mutate-quint.sh           # each CHECK_* switch off must break it, ~15 min
```

## Rules

1. A statement changes only with `Spec.lock` (`sha256sum Senzu/Spec.lean > Spec.lock`) in the same commit, so
   the change is reviewed. Proofs never edit `Spec.lean`.
2. Every statement has a mutant it refutes and a witness for its hypotheses.
3. A model change passes the vectors, and adds a mutation to `scripts/mutate-model.sh` that they catch.
4. No `sorry`, `admit`, `native_decide`, axioms or metaprogramming (`check.sh` greps, `Axioms.lean` checks).
5. After a contract math change: `cd sdk && just vectors`, then `scripts/check.sh` here.

## Statements

| | Statement | Mutant refuted | Proof |
|---|---|---|---|
| C1 | `toShares` down ≤ exact < down + 1; up ≥ exact > up − 1 | roundings swapped | proved (`Check.c1`) |
| C2 | the same for `toAssets` | roundings swapped | proved (`Check.c2`) |
| L1 | supply x, withdraw its shares: get back ≤ x | supply rounds up | proved (`Check.l1`) |
| L2 | that round trip loses < one share's price + 1 | supply without virtual shares; the rate reset in an emptied market | proved (`Check.l2`) |
| L3 | no supply, withdrawal or accrual lowers the share price | supply rounds up | proved (`Check.l3`) |
| L4 | no sequence of them does | withdraw rounds up | proved (`Check.l4`) |
| L5 | no free lunch: net assets out ≤ shares burned × starting price + interest, any sequence | withdraw rounds up, supply rounds up | proved (`Check.l5`) |
| B1 | right after borrowing d, the debt is ≥ d | borrow rounds down | proved (`Check.b1`) |
| B2 | repaying x (below the debt) burns shares worth ≤ x | repay rounds up | proved (`Check.b2`) |
| M1 | a market can't be bricked: through any sequence of actions, borrows ≤ supply, so `cash()` never underflows | write-off forgets `totalBorrowAssets` | proved (`Check.m1`) |
| W1 | a write-off that leaves other shares takes from lenders < the exact debt + 1 wei | write-off removes 1 wei extra | proved (`Check.w1`) |
| W2 | borrow d and be written off at once: lenders lose < d + one borrow share's price + 1 wei (in a market with no debt that no one owes) | write-off removes 1 wei extra | proved (`Check.w2`) |
| W3 | a write-off within `totalBorrowAssets` that leaves other shares doesn't raise anyone else's debt per share | write-off rounds down | proved (`Check.w3`) |
| W4 | writing off a market's last borrow shares leaves it no debt | the last shares' write-off takes only their debt (the code before 2026-11-20), leaving the virtual shares' part | proved (`Check.w4`) |
| B3 | a repayment that leaves shares never lowers the debt per borrow share (audit H-01) | repay books the rounded-up payment (the code before 2026-11-20) | proved (`Check.b3`) |
| B4 | a repayment adds exactly what it paid to the market's cash | repay drops what it paid over the shares' worth | proved (`Check.b4`) |
| B5 | the repayment of a market's last borrow shares leaves it no debt | the last shares book only their worth, leaving the virtual shares' wei | proved (`Check.b5`) |
| R1 | nothing gets stuck: after any steps, every checkpoint is at most the growth at any preview, and a payout never reverts (audit H-03) | a booking that sets the growth instead of adding to it | proved (`Check.r1`) |
| R2 | over any steps, a position pays out at most what arrived for it | payouts capped by what's held, not per position | proved (`Check.r2`) |
| R3 | a holder whose units don't change across a booking is credited at most its units' share of what arrived | the gain rounded up | proved (`Check.r3`) |
| FL1 | every holder can collect: after any steps, everything credited is at most what the position holds, and a holder poked and checkpointed is owed at most that | the gain rounded up | proved (`Check.fl1`) |
| FL2 | over any steps, a position pays out at most what the DEX earned for it | a poke that books the DEX's fees without collecting them | proved (`Check.fl2`) |
| FL3 | a holder whose units don't change across a poke is credited at most its units' share of what the DEX paid | a poke dividing by one unit fewer | proved (`Check.fl3`) |
| S1 | a seize moves the seized units' share of what the source could collect, credited fees included: nothing created, the receiver short by under 1 wei and one growth unit per unit, nothing left at 100% | the seize before 2026-11-24, which left credited fees with the source | proved (`Check.s1`) |
| S2 | a seize never reverts, so the fee ledger never blocks a liquidation (units and the preview within 256 bits) | credited fees divided by the receiver's units, which reverts on a liquidator's first seize | proved (`Check.s2`) |
| Q1 | a liquidation repays at most the debt and the offer, takes at most the units, and takes units worth at most repaid × the penalty borne | taking every unit repays the cover rounded down (0 for a cent of collateral) | proved (`Check.q1`) |
| Q2 | a liquidation lowers collateral − debts × the penalty borne by at most the adapter's rounding and, at the penalty, 2 wei and a borrow share's price of the debt plus 10^-18 USD | the units seized round up | proved (`Check.q2`) |
| Q3 | a position with collateral ≥ 1.02 × debts still has collateral ≥ debts after a liquidation, unless 2% of the debts left is under Q2's rounding | the penalty not shrunk to what the position bears | proved (`Check.q3`) |
| Q4 | while a borrow share is worth at most 1 wei, repaying a position's whole debt reverts neither in the liquidation nor in the market (audit M-02); it may take no units | taking every unit repays the cover rounded down | proved (`Check.q4`) |
| F1 | the liquidation fee is at most `feeWad` of the seized units' worth in the repaid asset less what was repaid, and nothing when that isn't positive | the fee on everything seized | proved (`Check.f1`) |
| F2 | no fee when collateral is under 1.02 × the debts, nor when the liquidation takes every unit and leaves debt to write off | no 1.02 floor (the first fee commit, 56985efa) | proved (`Check.f2`) |
| F3 | where F2 allows a fee, it is under its exact share by less than 1 wei + `feeWad` of (one USD-wei in the asset + 1 wei): under 1.2 wei at the 20% cap | the gain left in USD | proved (`Check.f3`) |
| H1 | a position whose value is concave in prices and passes the four-corner check is worth at least penalty × debts at every price pair in the box, other debts at or below their stressed price | only the two diagonal corners checked; debts valued at the oracle's prices | proved (`Check.h1`) |
| A1 | `amountsAt` never reports more than the slice's exact holdings at the √price it's given, and less by under one unit of liquidity's worth and 1 wei | the slice's liquidity rounded up | proved (`Check.a1`) |
| A2 | a range position's value (holdings after arbitrage, each token at its price) is concave in prices, so H1 applies to every adapter (`Check.rangePositionCovered`) | the two tokens swapped (√(pY / pX)) | proved (`Check.a2`) |
| A3 | `amountsAt` never reverts for a range inside Uniswap's, any `uint160` √price, `uint128` liquidity and slice | no guard for a position with no units | proved (`Check.a3`) |
| A4 | two slices of a position hold at most what their union holds: splitting units gains nothing | the slice's liquidity rounded up | proved (`Check.a4`) |

L1 alone accepts "withdraw rounds up" (the supply's rounding absorbs it); L4 and L5 reject it.

A known attack on lending markets chains three things: rounding leaves tiny positions underwater, each bad-debt
write-off takes ≥ 1 wei from lenders and can be repeated, and once a market's balance reaches 0 its exchange rate
resets, so the next deposit goes to the existing holders. Here W1/W2 bound what each
write-off takes, L2 rules out the reset (Senzu's virtual shares and assets have no special case at 0), and
Q2–Q4 bound the first step: rounding can leave a covered position underwater only when what's left is dust (when
every token's wei is worth at most $0.001, debt left under about $0.40, which a partial liquidation can leave of any
position), and dust never blocks its liquidation.

Q4 needs a borrow share worth at most 1 wei: debt that grew 10^6 times since the market opened, about 9 years at the
150% maximum rate. Past that, a dust repayment can burn 0 shares and revert (audit M-02).

W3's exception, found by fuzzing before freezing it, worked out by hand and not proved: a write-off's debt can
exceed `totalBorrowAssets` only once the debt per share has fallen below its starting price through rounding; the
shares left then owe under 1 wei in all. Since 2026-11-20 (audit M-03) lenders lose at most `totalBorrowAssets`
there, and B3 rules out the repayments that used to push the price down (audit H-01).

Since 2026-11-21 only what the DEX paid is booked, so a forfeit never reaches the ledger and nothing credited can
be taken back: rewards not yet paid at a seize go with the seized units.
