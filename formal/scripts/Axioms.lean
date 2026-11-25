import Senzu

/-!
Fails unless every declaration in `Senzu` depends only on Lean's three standard axioms. A `sorry`, a new
axiom or `native_decide` (which trusts compiled code) each show up here as an extra one.
-/

open Lean Elab Command

run_cmd do
  let env ← getEnv
  let allowed := #[``propext, ``Classical.choice, ``Quot.sound]
  let mut theorems := 0
  for (name, info) in env.constants.map₁.toList do
    let some idx := env.getModuleIdxFor? name | continue
    unless (`Senzu).isPrefixOf env.header.moduleNames[idx]! do continue
    for ax in ← collectAxioms name do
      unless allowed.contains ax do throwError "{name} depends on {ax}"
    if info matches .thmInfo _ then theorems := theorems + 1
  if theorems == 0 then throwError "no theorems found in Senzu"
  logInfo m!"{theorems} theorems, standard axioms only"
