#!/usr/bin/env bash
# Every CHECK_* switch in quint/lock.qnt, turned off, must make the lock proof fail.
set -euo pipefail
cd "$(dirname "$0")/../quint"
mkdir -p tmp
failed=0
for check in $(grep -oE 'pure val CHECK_[A-Z_]+ = true' lock.qnt | awk '{print $3}'); do
  sed "s/pure val $check = true/pure val $check = false/" lock.qnt > tmp/mutant.qnt
  if npx --no-install quint verify tmp/mutant.qnt --inductive-invariant=inductive --invariant=safe >tmp/mutant.log 2>&1; then
    echo "  $check off: the proof still holds (the switch checks nothing)"
    failed=1
  elif grep -q "violation" tmp/mutant.log; then
    echo "  $check off: fails, as it must"
  else
    echo "  $check off: the check errored instead of finding a violation (see quint/tmp/mutant.log)"
    failed=1
  fi
done
exit $failed
