#!/usr/bin/env bash
# Differential test suite. Runs every tests/NNN-*.pp under BOTH backends
# (tree-walker and bytecode VM) and diffs their output — any divergence is a
# failure — then runs the capability adversarial suite. Invoked by
# `dune runtest`; can also be run by hand from the repo root:
#
#     dune build && scripts/run-tests.sh ./pp
#
# Arg 1 is the pp binary (default: the dune-built one). The tests are run with
# the repo root as cwd so `(load "stdlib/list.pp")` resolves.
set -uo pipefail
PP="${1:-_build/default/src/main.exe}"
fail=0

for f in tests/[0-9]*.pp; do
  "$PP" --bytecode "$f" > /tmp/pp-bc.out 2>&1
  "$PP"             "$f" > /tmp/pp-tw.out 2>&1
  if diff -u /tmp/pp-tw.out /tmp/pp-bc.out > /tmp/pp-diff.out; then
    echo "ok   $f"
  else
    echo "FAIL $f  (backends disagree)"
    cat /tmp/pp-diff.out
    fail=1
  fi
done

echo "--- capability adversarial suite ---"
if PP="$PP" bash tests/capability-adversarial.sh; then
  :
else
  fail=1
fi

echo "--- node-cache trace suite ---"
if PP="$PP" bash tests/010-node-cache-trace.sh; then
  :
else
  fail=1
fi

echo "--- node-key (LAW 20) suite ---"
if PP="$PP" bash tests/011-node-key-law20.sh; then
  :
else
  fail=1
fi

echo "--- node-failure trace (LAW 28) suite ---"
if PP="$PP" bash tests/012-node-failure-trace.sh; then
  :
else
  fail=1
fi

echo "--- node-hit capability (LAW 23b) suite ---"
if PP="$PP" bash tests/013-node-hit-capability.sh; then
  :
else
  fail=1
fi

echo "--- VM node parity (D7) suite ---"
if PP="$PP" bash tests/014-vm-node-parity.sh; then
  :
else
  fail=1
fi

echo "--- config/handler trace cells (LAW 33/26) suite ---"
if PP="$PP" bash tests/015-config-handler-cells.sh; then
  :
else
  fail=1
fi

echo "--- cutoff (LAW 21, exit criteria 2/5) suite ---"
if PP="$PP" bash tests/016-cutoff.sh; then
  :
else
  fail=1
fi

echo "--- run effect + sandbox (D13) suite ---"
if PP="$PP" bash tests/017-run-effect.sh; then
  :
else
  fail=1
fi

echo "--- reconciler (Q4) suite ---"
if PP="$PP" bash tests/018-reconcile.sh; then
  :
else
  fail=1
fi

echo "--- why / no-cache / check suite ---"
if PP="$PP" bash tests/019-why-nocache-check.sh; then
  :
else
  fail=1
fi

echo "--- loader authority (Q6/D8c) suite ---"
if PP="$PP" bash tests/020-loader-authority.sh; then
  :
else
  fail=1
fi

echo "--- CAS ingest (Q11) suite ---"
if PP="$PP" bash tests/021-cas-ingest.sh; then
  :
else
  fail=1
fi

echo "--- depfile adapter (Q2) suite ---"
if PP="$PP" bash tests/022-depfile.sh; then
  :
else
  fail=1
fi

echo "--- blob reconcile suite ---"
if PP="$PP" bash tests/023-blob-reconcile.sh; then
  :
else
  fail=1
fi

echo "--- def value-binding suite ---"
if PP="$PP" bash tests/025-def-value.sh; then
  :
else
  fail=1
fi

echo "--- param type annotation suite ---"
if PP="$PP" bash tests/026-param-types.sh; then
  :
else
  fail=1
fi

echo "--- error message suite ---"
if PP="$PP" bash tests/027-error-messages.sh; then
  :
else
  fail=1
fi

echo "--- stdlib suite ---"
if PP="$PP" bash tests/028-stdlib.sh; then
  :
else
  fail=1
fi

echo "--- REPL suite ---"
if PP="$PP" bash tests/029-repl.sh; then
  :
else
  fail=1
fi

echo "--- Phase-1 exit criteria (100-TU C build) suite ---"
if PP="$PP" bash tests/024-phase1-exit.sh; then
  :
else
  fail=1
fi

echo "--- Phase 2 watch/once suite ---"
if PP="$PP" bash tests/031-watch-once.sh; then
  :
else
  fail=1
fi

echo "--- Phase 2 push stabilize (differential) suite ---"
if PP="$PP" bash tests/032-stabilize.sh; then
  echo "ok   032-stabilize"
else
  echo "FAIL 032-stabilize"; fail=1
fi

echo "--- Phase 2 process-domain reconciler suite ---"
if PP="$PP" bash tests/033-process-reconciler.sh; then
  echo "ok   033-process-reconciler"
else
  echo "FAIL 033-process-reconciler"; fail=1
fi

echo "--- Fenced effects (LAW 31) suite ---"
if PP="$PP" bash tests/034-fenced-effects.sh; then
  echo "ok   034-fenced-effects"
else
  echo "FAIL 034-fenced-effects"; fail=1
fi

echo "--- Islands (D2) suite ---"
if PP="$PP" bash tests/035-islands.sh; then
  echo "ok   035-islands"
else
  echo "FAIL 035-islands"; fail=1
fi

echo "--- Cell-id canonicalization (LAW 23) suite ---"
if PP="$PP" bash tests/036-canonical-cells.sh; then
  echo "ok   036-canonical-cells"
else
  echo "FAIL 036-canonical-cells"; fail=1
fi

echo "--- Portable store format (M2.2) suite ---"
if PP="$PP" bash tests/037-portable-store.sh; then
  echo "ok   037-portable-store"
else
  echo "FAIL 037-portable-store"; fail=1
fi

echo "--- Phase 3 parallel scheduler stress suite ---"
if PP="$PP" bash tests/038-parallel-stress.sh; then
  echo "ok   038-parallel-stress"
else
  echo "FAIL 038-parallel-stress"; fail=1
fi

echo "--- M3 capability attenuation suite ---"
if PP="$PP" bash tests/040-caps-attenuation.sh; then
  echo "ok   040-caps-attenuation"
else
  echo "FAIL 040-caps-attenuation"; fail=1
fi

echo "--- M3 defmacro rekey (LAW 20 exit 3) suite ---"
if PP="$PP" bash tests/042-defmacro-rekey.sh; then
  echo "ok   042-defmacro-rekey"
else
  echo "FAIL 042-defmacro-rekey"; fail=1
fi

echo "--- M4 probes (LAW 37/38) suite ---"
if PP="$PP" bash tests/043-probes.sh; then
  echo "ok   043-probes"
else
  echo "FAIL 043-probes"; fail=1
fi

echo "--- M4 sealed cells (LAW 39) suite ---"
if PP="$PP" bash tests/044-sealed.sh; then
  echo "ok   044-sealed"
else
  echo "FAIL 044-sealed"; fail=1
fi

echo "--- M4 network suite ---"
if PP="$PP" bash tests/045-network.sh; then
  echo "ok   045-network"
else
  echo "FAIL 045-network"; fail=1
fi

exit $fail
