#!/usr/bin/env bash
# Generates the v1 golden-scenario coverage matrix from executable repository cases.
set -euo pipefail

cases=(
  'cold-warm-edit-revert|tests/010-node-cache-trace.sh'
  'unauthorized-cache-redaction|tests/040-caps-attenuation.sh'
  'parallel-race-cancellation|tests/038-parallel-stress.sh'
  'remote-hit-fallback|tests/048-remote-placement.sh'
  'network-faults|tests/104-simulator-lab.sh'
  'worker-crash|tests/073-crash-injection.sh'
  'reconciliation-drift|tests/046-domains.sh'
  'watch-stabilization|tests/032-stabilize.sh'
  'fenced-recovery|tests/034-fenced-effects.sh'
  'failure-trace|tests/073-crash-injection.sh'
  'secret-rotation|tests/052-devops-complete.sh'
  'store-gc|tests/050-gc.sh'
  'mixed-language-surface|tests/105-simulator-language-coverage.sh'
)

printf 'scenario\texecutable evidence\n'
for row in "${cases[@]}"; do
  scenario=${row%%|*}; evidence=${row#*|}
  [ -f "$evidence" ] || { echo "missing executable golden evidence: $evidence" >&2; exit 1; }
  printf '%s\t%s\n' "$scenario" "$evidence"
done
[ "${#cases[@]}" -eq 13 ]
