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

echo "--- Q13 domains (in-language reconciler-domain protocol) suite ---"
if PP="$PP" bash tests/046-domains.sh; then
  echo "ok   046-domains"
else
  echo "FAIL 046-domains"; fail=1
fi

echo "--- M5 stage A cluster transport/token sync suite ---"
if PP="$PP" bash tests/047-cluster-sync.sh; then
  echo "ok   047-cluster-sync"
else
  echo "FAIL 047-cluster-sync"; fail=1
fi

echo "--- M5 stage B remote placement suite ---"
if PP="$PP" bash tests/048-remote-placement.sh; then
  echo "ok   048-remote-placement"
else
  echo "FAIL 048-remote-placement"; fail=1
fi

echo "--- M5 stage C host-qualified domain distribution suite ---"
if PP="$PP" bash tests/049-host-domains.sh; then
  echo "ok   049-host-domains"
else
  echo "FAIL 049-host-domains"; fail=1
fi

echo "--- M5 stage C store GC suite ---"
if PP="$PP" bash tests/050-gc.sh; then
  echo "ok   050-gc"
else
  echo "FAIL 050-gc"; fail=1
fi

echo "--- M5 exit battery (stage C gaps) suite ---"
if PP="$PP" bash tests/051-cluster-exit.sh; then
  echo "ok   051-cluster-exit"
else
  echo "FAIL 051-cluster-exit"; fail=1
fi

echo "--- M6 stage A: devops-complete demo + diagonal oracle ---"
if PP="$PP" bash tests/052-devops-complete.sh; then
  echo "ok   052-devops-complete"
else
  echo "FAIL 052-devops-complete"; fail=1
fi

echo "--- M6 stage B: observation-pinning seam (--pin-file/--dump-pins/pin-probe) ---"
if PP="$PP" bash tests/053-pin-observations.sh; then
  echo "ok   053-pin-observations"
else
  echo "FAIL 053-pin-observations"; fail=1
fi

echo "--- M7 S1: brace reader + location-preserving printer + roundtrip gate ---"
if PP="$PP" FUZZ="${FUZZ:-tools/fuzz.exe}" bash tests/054-brace-reader.sh; then
  echo "ok   054-brace-reader"
else
  echo "FAIL 054-brace-reader"; fail=1
fi

echo "--- M7 S2: pp fmt (lossless comment-carrying transpilation, both directions) ---"
if PP="$PP" bash tests/055-fmt.sh; then
  echo "ok   055-fmt"
else
  echo "FAIL 055-fmt"; fail=1
fi

echo "--- M7 S5: defmacro authored in braces vs sexpr, differentially ---"
if PP="$PP" bash tests/056-defmacro-both-surfaces.sh; then
  echo "ok   056-defmacro-both-surfaces"
else
  echo "FAIL 056-defmacro-both-surfaces"; fail=1
fi

echo "--- Phase 3.1: match list patterns (differential) ---"
if PP="$PP" bash tests/057-match-list-patterns.sh; then
  echo "ok   057-match-list-patterns"
else
  echo "FAIL 057-match-list-patterns"; fail=1
fi
echo "--- Phase 1b.4: collect { } error partitioning (differential) ---"
if PP="$PP" bash tests/058-collect.sh; then
  echo "ok   058-collect"
else
  echo "FAIL 058-collect"; fail=1
fi
echo "--- A1: deterministic try lowering (LAW-20 hash independent of parse order) ---"
if PP="$PP" bash tests/059-try-determinism.sh; then
  echo "ok   059-try-determinism"
else
  echo "FAIL 059-try-determinism"; fail=1
fi
if PP="$PP" bash tests/060-qq-list-parity.sh; then
  echo "ok   060-qq-list-parity"
else
  echo "FAIL 060-qq-list-parity"; fail=1
fi
echo "--- A3: quasiquote coverage of try/match/index/spread (differential + parity) ---"
if PP="$PP" bash tests/061-qq-sugar-coverage.sh; then
  echo "ok   061-qq-sugar-coverage"
else
  echo "FAIL 061-qq-sugar-coverage"; fail=1
fi
if PP="$PP" bash tests/061b-qq-head-coverage.sh; then
  echo "ok   061b-qq-head-coverage"
else
  echo "FAIL 061b-qq-head-coverage"; fail=1
fi
echo "--- A4: else-newline misparse (differential) ---"
if PP="$PP" bash tests/062-else-newline.sh; then
  echo "ok   062-else-newline"
else
  echo "FAIL 062-else-newline"; fail=1
fi
echo "--- A5: match lowering unshadowable primitives (differential) ---"
if PP="$PP" bash tests/063-match-shadow.sh; then
  echo "ok   063-match-shadow"
else
  echo "FAIL 063-match-shadow"; fail=1
fi
echo "--- A7(i): L9 vector-on-bracket-literal lint sweep ---"
if PP="$PP" bash tests/064-l9-vector-sweep.sh; then
  echo "ok   064-l9-vector-sweep"
else
  echo "FAIL 064-l9-vector-sweep"; fail=1
fi
echo "--- A7(iii): try{} <- rebind shadows (differential) ---"
if PP="$PP" bash tests/065-try-rebind-shadow.sh; then
  echo "ok   065-try-rebind-shadow"
else
  echo "FAIL 065-try-rebind-shadow"; fail=1
fi
echo "--- A6/A′1: table-driven \$KIND observation heads (differential) ---"
if PP="$PP" bash tests/066-dollar-heads.sh; then
  echo "ok   066-dollar-heads"
else
  echo "FAIL 066-dollar-heads"; fail=1
fi
exit $fail
