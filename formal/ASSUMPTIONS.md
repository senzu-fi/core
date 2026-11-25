# Assumptions

What the proofs rely on without proving it.

## Trusted

- Lean's kernel and Mathlib.
- solc and the EVM: the model is compared with the Solidity's behavior, not with bytecode semantics.
- The link from model to contract is the vectors: random cases for every modeled function (`Vectors.lean` lists
  the files), reverts included. Tests, not a proof. `scripts/mutate-model.sh` shows they catch each listed
  model mutation.

## Write-offs run through a harness

`write_off.txt` comes from `script/sdk/WriteOffHarness.sol`: `SenzuBorrowable` unchanged, plus one
entry point that writes a market and a position into its storage and calls the real `_writeOff`. Its wiring is
zero, which is exact here: with no time elapsed and no rewarder, `_writeOff` calls no other contract. The
states it sets need not be reachable, as with every vector; that only widens what is checked.

## `marketStep` allows more than the contract

A repayment or write-off may name any number of borrow shares up to the total, not just one position's, and
supplies have no zero-amount or `uint128` checks. The withdrawal's cash check and `addDebt`/`repayAmounts` are
the contract's.

An accrual may also add interest to a market with no borrow shares, so "no debt that no one owes" (W2's hypothesis)
isn't an invariant of `marketRun`. It is of the contract, argued, not proved: a market starts empty, interest
accrues only on borrowed assets, a borrow mints at least one share, and the last shares' repayment (B5) and
write-off (W4) leave no debt.

## The lender state machine allows more than the contract

`Lending.step` has no zero-amount reverts, no `uint128` caps, no allowances, and limits a withdrawal by all
assets rather than cash. The contract's behaviors are a subset, so a safety statement ("nothing bad happens")
proved for the model holds for the contract. A statement that something *can* happen would not transfer.

The borrow fee's shares and the reserve's shares are modeled as supplies: `addDebt` mints
`toShares(fee, supplyAssets, …)` and adds the fee, `MarketLogic.accrue` mints `toShares(reserve, supplyAssets −
reserve, …)` after adding the interest, which is an accrual of `interest − reserve` followed by a supply of
`reserve`.

## The fee ledger is one position, one token

`Fees.lean` models one position's fees in one token: each position and each token has its own storage and the same
code. The DEX's side is `pending`, what it owes the position: `accrue` adds to it and `poke` collects all of it, as
`_collectPending` does. What the DEX itself computes (Uniswap's fee growth, Aero's gauge) isn't modeled, so FL2 is
"paid at most what the DEX paid us", not "what the pool earned". `pay` is `_payFeesOwed` before the protocol's cut;
the cut only lowers what a holder receives.

`poke` divides by the sum of the holders' units, `totalSupply(lpId)`. The contract divides by the position's
liquidity at the DEX, so FL1 and FL3 rely on the adapter keeping the two equal. That is tested, not proved: the
invariant suites check `totalSupply(id) ==` the position's liquidity (`HubInvariant`, `V3Handler`, `V4Handler`,
`AeroHandler`, `AutomatorMedusa`).

S2 assumes the units fit in 256 bits and that `_previewGrowth`'s add doesn't pass 2^256: about 3.4·10^38 wei of fees
per unit of liquidity, and `_bookFees` reverts on the same add first.

`fee_ledger.txt` comes from `script/sdk/FeeLedgerHarness.sol`: `HeldFeesAdapter` unchanged, with a pretend
DEX that pays all its pending fees in token0 when collected. Its mint and burn are an adapter's increase and decrease
(collect, `_checkpointHeld`, change the units), its collect is the real `collectFees`, and its seize is the real
`seize` followed by the core's unit move. Token1's code is the same as token0's and isn't exercised.

## Liquidations start from the health check's numbers

`Liquidation.liquidate` is `LiquidationLogic.seizeFor`: its arguments are the collateral and debts in USD that
`HealthLogic` computed, so Q1–Q4 hold whatever the oracle and the adapter say. They don't cover the check before
it (only a position with `minSurplusUsdWad < 0` gets there), nor how the health check prices debts, beyond Q2–Q4's
hypothesis that the repaid debt is its shares rounded up, priced rounded up (`_debtAssets`, `mulDivRoundingUp`).
Q2 and Q3 take the adapter's rounding as an argument, `adapterRounding`: the units a position keeps are worth at
least their share of `C` less it (`Liquidated`'s last hypothesis). All five adapters value units through
`RangeAmounts.ofUnits`, which floors the slice's liquidity (`liquidityOf`), each token amount
(`getAmountsForLiquidity`) and each token's USD (`valueUsd`): under one unit of liquidity's worth, 1 wei of each
pair token and 2·10^-18 USD. The token amounts' part is A1; the USD part is by our reading of the code, not proved
here. 1 wei of WBTC is $0.001 at $100k, far
more than one unit's worth in a WBTC pair, which an earlier draft of `Liquidated` assumed (review of 2026-11-20).

## The health check is modeled exactly

H1 and A2 are about the check in ℝ: exact prices, the √price exactly √(pX / pY), debts at exactly their stressed
value. The contract rounds the √price down and holdings at a slightly wrong √price are worth slightly more than
the holdings after arbitrage, so the integer check can over-report by a second-order amount. Until 2026-11-21 the
root kept 64 fractional bits, up to a quarter of a position's value near Uniswap's lowest √price; it keeps 96 below a
ratio of 2^64 now. The debts round up, in the protocol's favor. H2
(`CheckErrsOnlyBySqrtSlack` in `Spec.lean`) bounds the integer check against the exact one; its proof is in progress
(`Proofs/Rounding.lean` has the slack bound and the √price's error so far).

`liquidityOf` and `rangeAt`'s zero-liquidity shortcut have no vectors of their own: they are `mulDiv`, `toU128`
and a comparison, each covered elsewhere. The adapters' `totalLiq` (v2's from √k and the supply, Ekubo's net of its
withdrawal fee) is an argument, so A1–A4 hold whatever it is.

## Not modeled yet

- Interest computation: `accrue i` adds `i`; `MarketLogic.accrue` (rate, remainder carry) isn't modeled.
- Bad-debt write-off: lowers the share price on purpose, so L3–L5 exclude it.
- Borrowers' debts over a sequence: B1, B2 are about single conversions, M1 only about the totals.
- Who may write off: a liquidation that takes the last unit (in its lock), or `resolveBadDebt` for collateral worth 0
  (outside a lock). That only price-made bad debt is written off is proved in the Quint lock model
  (`quint/lock.qnt`), not here.
- Tokens: transfers move exact amounts (`_pullExact`).
- Health, adapters, oracle prices (liquidations start from their numbers, above).
