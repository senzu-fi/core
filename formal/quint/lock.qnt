// -*- mode: Bluespec; -*-
// A model of SenzuCollateral's lock(): deferred health checks, seize-first liquidations and settle, over one
// position id, two debt assets (a position owes at most two) and the fees the core books to reserves. Amounts are
// small integers and both debt assets are worth 1; interest, shares and rounding are left out (the Lean proofs and
// the Foundry invariants cover those).
// Run: npx @informalsystems/quint@0.33.1 run lock.qnt --invariant=safe --max-samples=500000 --max-steps=60
// Prove (Apalache, every depth): npx @informalsystems/quint@0.33.1 verify lock.qnt --inductive-invariant=inductive --invariant=safe
//   `inductive` holds at init and every step keeps it from any state where it holds, and it implies `safe`
//   (first proved 2026-11-12; two assets and both fees 2026-11-24). `formal/scripts/check.sh` runs it.
// Each CHECK_* switch set to false must make the proof fail (`formal/scripts/mutate-quint.sh`)
module lock {
  type Account = str
  type Asset = str

  type State = {
    price: int,                         // USD per unit of collateral
    units: Account -> int,
    debt: Account -> Asset -> int,
    supply: Asset -> int,               // market.totalSupplyAssets
    borrowed: Asset -> int,             // market.totalBorrowAssets
    tokens: Asset -> int,               // what the borrowable really holds
    locker: Account,                    // "" outside a lock
    deferred: Set[Account],
    unsettled: Asset -> int,
    wasHealthy: Account -> bool,        // each account's health right after the last price move
    seizedHealthy: bool,                // a liquidation took units from an account that was healthy then
    wroteOffHealthy: bool,              // a write-off erased the debt of an account that was healthy then
    feeOnBadDebt: bool                  // a liquidation took a fee and wrote debt off
  }

  pure val ACCOUNTS = Set("alice", "bob", "carol")
  pure val ASSETS = Set("usd", "eth")
  pure val AMOUNTS = 1.to(6)
  pure val PRICES = 1.to(4)
  // A liquidation's repayment reaches 30: the fee-leaves-debt case lies between the 1.1 penalty and 1.02, which
  // whole amounts first reach at a repayment of 13
  pure val REPAYS = 1.to(30)
  pure val FEES = 0.to(2)                // a borrow's fee: any amount, the risk config's rate rounded
  // Mutation switches: the model must break when one is turned off
  pure val CHECK_PENDING = true      // liquidate refuses a position with a pending deferred check
  pure val CHECK_UNSETTLED = true    // lock() ends only with nothing unsettled, the fee included
  pure val CHECK_DEFERRED = true     // lock() ends only with every changed position healthy
  pure val CHECK_UNLOCKED_WRITE_OFF = true // resolveBadDebt never runs inside a lock
  pure val CHECK_LIQUIDATION_WRITE_OFF = true // a liquidation that takes the last unit writes off the debt left
  pure val CHECK_WRITE_OFF_BOTH = true // that write-off clears both debts, not only the one repaid
  pure val CHECK_FEE_LEAVES_DEBT = true // no fee when the liquidation leaves debt to write off
  pure val CHECK_BORROW_FEE_IN_HEALTH = true // a borrow's health check counts its fee as debt

  pure def min(a: int, b: int): int = if (a < b) a else b
  pure def ceilDiv(a: int, b: int): int = (a + b - 1) / b
  pure def owed(st: State, a: Account): int = ASSETS.fold(0, (sum, x) => sum + st.debt.get(a).get(x))
  // collateral >= debt * 1.2 (stress and penalty together)
  pure def healthy(st: State, a: Account): bool = st.units.get(a) * st.price * 10 >= owed(st, a) * 12
  pure def cash(st: State, x: Asset): int = st.supply.get(x) - st.borrowed.get(x)
  pure def locked(st: State): bool = st.locker != ""
  pure def addDebt(st: State, a: Account, x: Asset, n: int): Account -> Asset -> int =
    st.debt.setBy(a, d => d.setBy(x, v => v + n))
  pure def zeroes: Asset -> int = ASSETS.mapBy(_ => 0)

  var price: int
  var units: Account -> int
  var debtUsd: Account -> int        // `debt` split by asset: the inductive check starts from a map of ints
  var debtEth: Account -> int
  var supplied: Asset -> int
  var borrowed: Asset -> int
  var tokens: Asset -> int
  var locker: Account
  var deferred: Set[Account]
  var unsettled: Asset -> int
  var wasHealthy: Account -> bool
  var seizedHealthy: bool
  var wroteOffHealthy: bool
  var feeOnBadDebt: bool

  // One variable per field (the inductive check starts from any value of each); `s` reads them as one record
  val s: State = {
    price: price, units: units,
    debt: ACCOUNTS.mapBy(a => Map("usd" -> debtUsd.get(a), "eth" -> debtEth.get(a))), supply: supplied, borrowed: borrowed, tokens: tokens, locker: locker,
    deferred: deferred, unsettled: unsettled, wasHealthy: wasHealthy, seizedHealthy: seizedHealthy,
    wroteOffHealthy: wroteOffHealthy, feeOnBadDebt: feeOnBadDebt
  }

  action become(st: State): bool = all {
    price' = st.price, units' = st.units, debtUsd' = ACCOUNTS.mapBy(a => st.debt.get(a).get("usd")),
    debtEth' = ACCOUNTS.mapBy(a => st.debt.get(a).get("eth")), supplied' = st.supply, borrowed' = st.borrowed,
    tokens' = st.tokens, locker' = st.locker, deferred' = st.deferred, unsettled' = st.unsettled,
    wasHealthy' = st.wasHealthy, seizedHealthy' = st.seizedHealthy, wroteOffHealthy' = st.wroteOffHealthy,
    feeOnBadDebt' = st.feeOnBadDebt,
  }

  action init = become({
    price: 2, units: ACCOUNTS.mapBy(_ => 0), debt: ACCOUNTS.mapBy(_ => zeroes), supply: zeroes, borrowed: zeroes,
    tokens: zeroes, locker: "", deferred: Set(), unsettled: zeroes, wasHealthy: ACCOUNTS.mapBy(_ => true),
    seizedHealthy: false, wroteOffHealthy: false, feeOnBadDebt: false
  })

  action supply(x: Asset, n: int): bool =
    become({ ...s, supply: s.supply.setBy(x, v => v + n), tokens: s.tokens.setBy(x, v => v + n) })

  action withdraw(x: Asset, n: int): bool = all {
    n <= cash(s, x), n <= s.tokens.get(x),
    become({ ...s, supply: s.supply.setBy(x, v => v - n), tokens: s.tokens.setBy(x, v => v - n) })
  }

  action addUnits(a: Account, n: int): bool = become({ ...s, units: s.units.setBy(a, u => u + n) })

  action redeem(a: Account, n: int): bool = {
    val after = { ...s, units: s.units.setBy(a, u => u - n) }
    all {
      n <= s.units.get(a),
      if (owed(s, a) == 0) become(after)
      else if (locked(s)) become({ ...after, deferred: s.deferred.union(Set(a)) })
      else all { healthy(after, a), become(after) }
    }
  }

  // The fee is added to the debt and to the lenders' supply (reserves' shares), and only `n` leaves
  action borrow(a: Account, x: Asset, n: int, fee: int): bool = {
    val after = { ...s, debt: addDebt(s, a, x, n + fee), borrowed: s.borrowed.setBy(x, v => v + n + fee),
      supply: s.supply.setBy(x, v => v + fee), tokens: s.tokens.setBy(x, v => v - n) }
    val checked = if (CHECK_BORROW_FEE_IN_HEALTH) after else { ...after, debt: addDebt(s, a, x, n) }
    all {
      n <= cash(s, x), n <= s.tokens.get(x),
      if (locked(s)) become({ ...after, deferred: s.deferred.union(Set(a)) })
      else all { healthy(checked, a), become(after) }
    }
  }

  action repay(a: Account, x: Asset, n: int): bool = all {
    n <= s.debt.get(a).get(x),
    become({ ...s, debt: addDebt(s, a, x, -n), borrowed: s.borrowed.setBy(x, v => v - n),
      tokens: s.tokens.setBy(x, v => v + n) })
  }

  // Seize first: the repayment and the protocol's fee are booked now and paid by settle() before the lock ends.
  // Penalty 1.1, and a liquidator that takes every unit pays at least collateral / 1.02. Taking the last unit writes
  // off every debt left (nothing backs it), in the same call. The fee is half the liquidator's gain, none when the
  // position is underwater or the liquidation leaves debt to write off
  action liquidate(b: Account, receiver: Account, x: Asset, n: int): bool = {
    val u = s.units.get(b)
    val d = s.debt.get(b).get(x)
    val want = min(n, d)
    val seizedRaw = want * 11 / (10 * s.price)
    val seized = min(seizedRaw, u)
    val repaid = if (seizedRaw > u) min(want, ceilDiv(u * s.price * 100, 102)) else want
    val writesOff = CHECK_LIQUIDATION_WRITE_OFF and seized == u
    val rest: Asset -> int = ASSETS.mapBy(y =>
      if (not(writesOff)) 0
      else if (y == x) d - repaid
      else if (CHECK_WRITE_OFF_BOTH) s.debt.get(b).get(y) else 0)
    val underwater = u * s.price * 100 < owed(s, b) * 102
    val leavesDebt = seized == u and (repaid < d or owed(s, b) > d)
    val gain = seized * s.price - repaid
    val fee = if (underwater or (CHECK_FEE_LEAVES_DEBT and leavesDebt) or gain <= 0) 0 else gain / 2
    val writtenOff = ASSETS.fold(0, (sum, y) => sum + rest.get(y))
    all {
      locked(s), b != receiver,
      not(CHECK_PENDING) or not(s.deferred.contains(b)),
      not(healthy(s, b)), u > 0, repaid > 0,
      become({ ...s, seizedHealthy: s.seizedHealthy or s.wasHealthy.get(b),
        wroteOffHealthy: s.wroteOffHealthy or (writtenOff > 0 and s.wasHealthy.get(b)),
        feeOnBadDebt: s.feeOnBadDebt or (fee > 0 and writtenOff > 0),
        debt: s.debt.set(b, ASSETS.mapBy(y => s.debt.get(b).get(y) - (if (y == x) repaid else 0) - rest.get(y))),
        borrowed: ASSETS.mapBy(y => s.borrowed.get(y) - (if (y == x) repaid else 0) - rest.get(y)),
        supply: ASSETS.mapBy(y => {
          val v = s.supply.get(y) + (if (y == x) fee else 0)
          if (rest.get(y) > v) 0 else v - rest.get(y)
        }),
        unsettled: s.unsettled.setBy(x, v => v + repaid + fee),
        units: s.units.setBy(b, v => v - seized).setBy(receiver, v => v + seized) })
    }
  }

  action settle(x: Asset, n: int): bool = all {
    locked(s), n <= s.unsettled.get(x),
    become({ ...s, unsettled: s.unsettled.setBy(x, v => v - n), tokens: s.tokens.setBy(x, v => v + n) })
  }

  action resolveBadDebt(b: Account): bool = all {
    not(CHECK_UNLOCKED_WRITE_OFF) or not(locked(s)), owed(s, b) > 0, s.units.get(b) == 0,
    become({ ...s, wroteOffHealthy: s.wroteOffHealthy or s.wasHealthy.get(b), debt: s.debt.set(b, zeroes),
      borrowed: ASSETS.mapBy(y => s.borrowed.get(y) - s.debt.get(b).get(y)),
      supply: ASSETS.mapBy(y => if (s.debt.get(b).get(y) > s.supply.get(y)) 0 else s.supply.get(y) - s.debt.get(b).get(y)) })
  }

  action lockBegin(a: Account): bool = all { not(locked(s)), become({ ...s, locker: a }) }

  action lockEnd: bool = all {
    locked(s),
    not(CHECK_UNSETTLED) or ASSETS.forall(x => s.unsettled.get(x) == 0),
    not(CHECK_DEFERRED) or s.deferred.forall(a => owed(s, a) == 0 or healthy(s, a)),
    become({ ...s, locker: "", deferred: Set() })
  }

  // Prices move between transactions only
  action setPrice(p: int): bool = {
    val after = { ...s, price: p }
    all { not(locked(s)), become({ ...after, wasHealthy: ACCOUNTS.mapBy(a => healthy(after, a)), seizedHealthy: false,
      wroteOffHealthy: false, feeOnBadDebt: false }) }
  }

  action step = {
    nondet a = ACCOUNTS.oneOf()
    nondet b = ACCOUNTS.oneOf()
    nondet x = ASSETS.oneOf()
    nondet n = AMOUNTS.oneOf()
    nondet m = REPAYS.oneOf()
    nondet f = FEES.oneOf()
    nondet p = PRICES.oneOf()
    any {
      supply(x, n), withdraw(x, n), addUnits(a, n), redeem(a, n), borrow(a, x, n, f), repay(a, x, n),
      liquidate(a, b, x, m), settle(x, n), resolveBadDebt(a), lockBegin(a), lockEnd, setPrice(p)
    }
  }

  // The borrowable holds its book cash, less what a lock still owes it, in each asset
  val backed = ASSETS.forall(x =>
    s.tokens.get(x) + s.unsettled.get(x) == cash(s, x) and s.tokens.get(x) >= 0 and cash(s, x) >= 0)
  val debtsAddUp = ASSETS.forall(x => ACCOUNTS.fold(0, (sum, a) => sum + s.debt.get(a).get(x)) == s.borrowed.get(x))
  val lockLeavesNothing = locked(s) or (ASSETS.forall(x => s.unsettled.get(x) == 0) and s.deferred == Set())
  // Only a price move makes a position liquidatable: outside a lock, whoever was healthy after the last price
  // move still is
  val onlyPricesBreakHealth = locked(s) or ACCOUNTS.forall(a => s.wasHealthy.get(a) implies healthy(s, a))
  // Bad debt (debt with no units) comes only from liquidating a position that a price move made unhealthy
  val noBadDebtWithoutPriceMove =
    locked(s) or ACCOUNTS.forall(a => s.wasHealthy.get(a) implies not(owed(s, a) > 0 and s.units.get(a) == 0))

  // Units leave an account only when a price move, not its own lock's actions, made it liquidatable
  val onlyPricesAllowSeizing = not(s.seizedHealthy)
  // Lenders lose only what a price move made bad: a write-off never erases the debt of an account that was healthy
  // after the last one (borrow everything then write it off, in one lock or one transaction, is this)
  val onlyPricesAllowWriteOffs = not(s.wroteOffHealthy)
  // The protocol never takes a fee out of a liquidation that leaves the lenders a loss
  val noFeeOnBadDebt = not(s.feeOnBadDebt)

  // Bad debt never waits on the lenders' books: between transactions, an account with debt holds units
  val noWaitingBadDebt = locked(s) or ACCOUNTS.forall(a => s.units.get(a) == 0 implies owed(s, a) == 0)

  val safe = and {
    noWaitingBadDebt, onlyPricesAllowSeizing, onlyPricesAllowWriteOffs, noFeeOnBadDebt, backed, debtsAddUp,
    lockLeavesNothing, onlyPricesBreakHealth, noBadDebtWithoutPriceMove,
  }

  // Inductive: holds at init and every step keeps it, from any state where it holds, so `safe` holds at every depth
  // Every value of every variable, amounts unbounded: where the inductive check starts
  val typeOK = and {
    price.in(PRICES), units.in(setOfMaps(ACCOUNTS, Nat)), debtUsd.in(setOfMaps(ACCOUNTS, Nat)),
    debtEth.in(setOfMaps(ACCOUNTS, Nat)),
    supplied.in(setOfMaps(ASSETS, Int)), borrowed.in(setOfMaps(ASSETS, Int)), tokens.in(setOfMaps(ASSETS, Nat)),
    locker.in(ACCOUNTS.union(Set(""))), deferred.in(powerset(ACCOUNTS)), unsettled.in(setOfMaps(ASSETS, Nat)),
    wasHealthy.in(setOfMaps(ACCOUNTS, Bool)), seizedHealthy.in(Bool), wroteOffHealthy.in(Bool),
    feeOnBadDebt.in(Bool),
  }
  // Inside a lock too: an account healthy after the last price move stays so until it has a check pending
  val healthyUntilChanged =
    ACCOUNTS.forall(a => (s.wasHealthy.get(a) and not(s.deferred.contains(a))) implies healthy(s, a))
  val inductive = and {
    typeOK, backed, debtsAddUp, lockLeavesNothing, healthyUntilChanged, onlyPricesAllowSeizing,
    onlyPricesAllowWriteOffs, noFeeOnBadDebt,
    ACCOUNTS.forall(a => (s.units.get(a) == 0 and not(s.deferred.contains(a))) implies owed(s, a) == 0),
  }
}
