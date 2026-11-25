#!/usr/bin/env bash
# Everything that must hold for the proofs to count.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.elan/bin:$PATH"

echo "== statements unchanged (Spec.lock)"
sha256sum --check --quiet Spec.lock

echo "== no escape hatches"
if grep -rnwE 'sorry|admit|native_decide|implemented_by|extern|unsafe|partial|opaque|axiom|macro|macro_rules|elab|syntax|notation|debug' \
  Senzu Senzu.lean Vectors.lean; then
  exit 1
fi

echo "== build, warnings fail"
lake build --wfail -q

echo "== standard axioms only"
lake env lean scripts/Axioms.lean

echo "== model matches the Solidity's vectors"
lake exe vectors

echo "== every model mutation fails the vectors"
scripts/mutate-model.sh

# quint may live under nvm
if [ -s "$HOME/.nvm/nvm.sh" ]; then set +u; . "$HOME/.nvm/nvm.sh" >/dev/null; set -u; fi

echo "== Quint lock model, proved at every depth"
(cd quint && npx --no-install quint verify lock.qnt --inductive-invariant=inductive --invariant=safe >/dev/null)

echo "== every Quint switch off breaks the proof"
scripts/mutate-quint.sh
