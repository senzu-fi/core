# Senzu Core

Lending against DEX liquidity positions. An LP position becomes collateral that borrows from its exchange's lending
markets. Each exchange, and each version of one (Uniswap v3 and v4 are separate), gets its own isolated deployment: a
pair of immutable contracts plus a shared risk configuration.

- **`SenzuBorrowable`**: the lenders' side. One lending market per asset (lender shares are ERC-6909, id = asset)
  and the debt of positions. Anyone can supply, withdraw and repay; only its paired collateral can open, move or
  write off debt.
- **`SenzuCollateral`**: the borrowers' side. LP positions (ERC-6909, id = position, balance = units), health
  checks, liquidations and `lock()`. Exchange-specific code lives in adapters.
- **`SenzuRiskConfig`**: stress factors, liquidation parameters, caps and pauses, per exchange.

This repository holds the core, its modules, the Uniswap v3 and v4 adapters, the routers that call them, the tests
and the formal proofs.

## Layout

```
src/
├── core/          SenzuCore (shared base) → SenzuBorrowable, SenzuCollateral
├── libraries/     HealthMath, HealthLogic, MarketLogic, BorrowLogic, LiquidationLogic, LockLogic, FeeLogic,
│                  DebtLanes, RangeAmounts (all inlined)
│   └── uniswap/   LiquidityAmounts, PoolAddress, UniswapV4State (on Uniswap's math)
├── modules/       SenzuFactory, SenzuRiskConfig, SenzuOracle (Chainlink), PythFeed (a Pyth feed read as a
│                  Chainlink aggregator)
│   └── deployers/ BorrowableDeployer, CollateralDeployer
├── adapters/      BaseAdapter, FeeLedger, HeldFeesAdapter, RewardLedger, PoolRegistry, UniswapV3Adapter,
│                  UniswapV4Adapter
├── periphery/     SenzuBaseRouter (+ routers/: Uniswap v3, v4, v3 paths), SenzuLens (batched reads),
│                  SenzuPreviews (position previews, not deployed)
├── tokens/        SenzuERC6909
├── types/         DebtLane, TransientSlot
└── interfaces/    the contracts' APIs, plus Pyth's interface files (external/pyth, unmodified)
test/              unit, fuzz and invariant tests (invariant/), Uniswap v3/v4 fork tests (fork/), Medusa harnesses
script/            SdkVectors: test vectors from the Solidity, which the Lean model replays
formal/            Lean 4 proofs about a model of the core math, and a Quint model of lock()
```

Libraries are git submodules in `lib/`, pinned: forge-std, OpenZeppelin, Solady, Uniswap v3-core, v3-periphery,
v4-core and v4-periphery, Permit2, and Chainlink. The factory's admin is OpenZeppelin's `TimelockController`.

## Build and test

```
git submodule update --init
forge build
forge test
FOUNDRY_PROFILE=solar forge test                                    # Solar: seconds instead of minutes
FOUNDRY_PROFILE=deep forge test --match-contract HubInvariantTest   # a longer invariant campaign
medusa fuzz                                                         # the Medusa campaign (medusa.json)
FOUNDRY_PROFILE=slither slither .                                   # static analysis
```

The default profile is the deployed build: solc 0.8.39, via-IR, 49,999 optimizer runs, `cancun`. The `solar` profile
is for everyday work; its bytecode differs from the deployed build. Fork tests read `ETH_RPC_URL` from `.env` (see
`.env.example`) and skip without it.

## Formal verification

`formal/` proves statements about a model of the core math in Lean 4 with Mathlib: share conversions, borrowing,
repayment, bad-debt write-offs, liquidations, the fee and reward ledgers, and range amounts. The model is tied to the
Solidity by the vectors in `formal/vectors/`, which `script/SdkVectors.s.sol` generates from the contracts. A Quint
model of `lock()` is proved at every depth with Apalache. See [formal/README.md](formal/README.md).

```
cd formal && scripts/check.sh
```

## Rules

- No proxies, no upgradeability. Changeable behavior lives in separate immutable modules the core points to.
- The core is exchange-agnostic. Exchange code lives only in adapters.
- The contracts and their defaults are the same on every chain.
- Liquidation parameters can only move in borrowers' favor.

## License

Licensed under the Business Source License 1.1 (`BUSL-1.1`), see [BUSL_LICENSE](licenses/BUSL_LICENSE), and the MIT
License (`MIT`), see [MIT_LICENSE](licenses/MIT_LICENSE). Each file states its license in the header: `BUSL-1.1` covers
the core (`src/core/`) and the libraries holding its logic (`BorrowLogic`, `DebtLanes`, `HealthLogic`,
`LiquidationLogic`, `LockLogic`, `MarketLogic`, `DebtLane`); everything else in `src/` and `script/` is `MIT`; tests
are `UNLICENSED`. Vendored code keeps its own license.
