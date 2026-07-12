#!/usr/bin/env bash
# ROADMAP Phase-1 exit criteria, run for real on a generated 100-TU C project
# built by a real build.pp (nodes + run-dep + blobs + reconcile).
#
#   1. Null rebuild executes ZERO external processes (the journal proves it)
#      and completes in <1s.
#   2. `touch` (mtime-only) on every input → zero recompiles.
#   3. Edit one f5.c → exactly f5.o + link re-run.
#   4. `rm -rf build/` → fully restored from the store, zero tool re-runs,
#      binary byte-identical.
#   5. Comment-only header edit → every dependent recompiles, link cut off.
#   7. Authority gates hits transitively: without the process grant, cached
#      run-node results are not served (tool: cells), nothing is laundered.
#   (6 — pp builds itself — lives in scripts/build-self.sh: it invokes dune,
#    which cannot nest inside `dune runtest`.)
#
# Requires cc; skips cleanly if absent. Isolated HOME.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

command -v cc >/dev/null 2>&1 || { echo "=== PHASE1 EXIT TEST SKIPPED (no cc) ==="; exit 0; }

TMP=$(mktemp -d)
export HOME="$TMP"
SRC="$TMP/src"; BUILD="$TMP/build"
mkdir -p "$SRC"
J="$TMP/.pp/store/journal/log"
N=100
fail=0

ok()   { echo "ok   $1"; }
bad()  { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

execs() { grep -c "^exec " "$J" 2>/dev/null; true; }
links() { grep -c "cc -o prog" "$J" 2>/dev/null; true; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

# ---- generate the project — in pp (ROADMAP §2 milestone: the fixture
# generator is a pp program; the pass/fail oracle in this file stays shell) ----
if ! "$PP" --grant "fs:$SRC:rw" tests/gen-cproject.pp -- "$N" "$SRC" 2>"$TMP/gen.err"; then
  echo "FAIL fixture-generator (pp)"; cat "$TMP/gen.err"; exit 1
fi
[ -f "$SRC/main.c" ] && [ -f "$SRC/f0.c" ] && grep -q '^main$' "$SRC/sources.txt" \
  || { echo "FAIL fixture-generator: files missing"; exit 1; }
TU=$((N + 1))

# ---- build.pp — the real thing: manifest-driven, nodes all the way ----
#
# Phase 3 (docs/PLAN-phase3-parallel.md): `compile` builds but does NOT
# force its node — the pairing-trap-safe pattern is `(map compile names)`
# (map applies compile to each name via the apply hook WITHOUT forcing the
# result, per Wall A), `force-deep` THAT batch (the scheduler's fork
# fan-out point sees every sibling node before any of them runs), and only
# THEN pair names back up with the now-hit results via `zip2`. Do NOT
# rewrite this as `(map2 (fn (n) (cons n (compile n))) names)` — pairing
# `(compile n)` into `cons` there is an argument position, so EApply would
# force each node eagerly and in order right there, silently serializing
# the whole build back to one-at-a-time (the pairing trap the design
# review caught).
cat > "$TMP/build.pp" <<EOF
(def (each f lst) (if (nil? lst) nil (do (f (car lst)) (each f (cdr lst)))))
(def (foldl2 f acc lst) (if (nil? lst) acc (foldl2 f (f acc (car lst)) (cdr lst))))
(def (zip2 lst1 lst2)
  (if (nil? lst1) nil (cons (cons (car lst1) (car lst2)) (zip2 (cdr lst1) (cdr lst2)))))

(def (compile name)
  (node
    (do (perform run-dep (string-append name ".d")
          "cc" "-MD" "-MF" (string-append name ".d") "-O0" "-c"
          (string-append "$SRC/" (string-append name ".c"))
          "-o" (string-append name ".o"))
        (blob (slurp (string-append name ".o"))))))

(def (link objs)
  (force (node
    (do (each (fn (o) (perform write-file (string-append (car o) ".o")
                        (blob-get (cdr o)))) objs)
        (do (perform write-file "link.d" "prog: ")
            (do (perform run-dep "link.d" "sh" "-c"
                  (string-append "cc -o prog "
                    (foldl2 (fn (acc o) (string-append acc (string-append (car o) ".o ")))
                            "" objs)))
                (blob (slurp "prog"))))))))

(let [names (string-split (slurp "$SRC/sources.txt") "\n")]
  (let [results (force-deep (map compile names))]
    (let [objs (zip2 names results)]
      (let [prog (link objs)]
        (foldl2 (fn (m o) (map-insert m (string-append (car o) ".o") (cdr o)))
                (map-insert (hash-map) "prog" (string-append prog ":x"))
                objs)))))
EOF

G=(--grant "fs:$SRC:ro" --grant "fs:$BUILD:wo" --grant process)
run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# ---- cold build ----
rm -rf "$TMP/.pp" "$BUILD"
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
e0=$(execs)
if [ "$e0" -eq $((TU + 1)) ]; then ok "cold-exec-count ($e0 = $TU cc + 1 link)"
else bad "cold-exec-count: expected $((TU + 1)) execs, got $e0" "$(tail -5 "$TMP/out")"; fi
if [ -x "$BUILD/prog" ] && "$BUILD/prog"; then ok "cold-binary-runs"
else bad "cold-binary-runs"; fi
nobj=$(ls "$BUILD" | grep -c '\.o$')
if [ "$nobj" -eq "$TU" ]; then ok "cold-objects-materialized"
else bad "cold-objects-materialized: $nobj != $TU"; fi
cp "$BUILD/prog" "$TMP/prog.saved"

# ---- criterion 1: null rebuild — zero processes, <1s ----
t0=$(now_ms)
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
t1=$(now_ms)
e1=$(execs)
if [ "$e1" -eq "$e0" ]; then ok "c1-null-zero-processes (journal)"
else bad "c1-null-zero-processes: $((e1 - e0)) new execs"; fi
dt=$((t1 - t0))
if [ "$dt" -lt 1000 ]; then ok "c1-null-under-1s (${dt}ms)"
else bad "c1-null-under-1s: took ${dt}ms"; fi
grep -qE "create=0 update=0 delete=0" "$TMP/out" && ok "c1-null-reconcile" \
  || bad "c1-null-reconcile" "$(tail -3 "$TMP/out")"

# ---- criterion 2: touch everything — zero recompiles ----
touch -t 202001010000 "$SRC"/*
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
e2=$(execs)
if [ "$e2" -eq "$e1" ]; then ok "c2-touch-zero-recompiles"
else bad "c2-touch-zero-recompiles: $((e2 - e1)) new execs"; fi

# ---- criterion 3: edit one f5.c — exactly f5.o + link re-run ----
# (drift mutation in pp — ROADMAP §2 milestone)
"$PP" --grant "fs:$SRC:rw" tests/mutate-cproject.pp -- edit-tu "$SRC" 5 \
  || { echo "FAIL mutate edit-tu (pp)"; exit 1; }
l_before=$(links)
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
e3=$(execs); l_after=$(links)
if [ $((e3 - e2)) -eq 2 ] && [ $((l_after - l_before)) -eq 1 ]; then
  ok "c3-one-edit-two-execs (1 compile + 1 link)"
else bad "c3-one-edit-two-execs: $((e3 - e2)) execs, $((l_after - l_before)) links"; fi
if "$BUILD/prog"; then ok "c3-binary-still-runs"; else bad "c3-binary-still-runs"; fi

# ---- criterion 4: rm -rf build — restored from store, zero tool re-runs ----
cp "$BUILD/prog" "$TMP/prog.c3"
rm -rf "$BUILD"
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
e4=$(execs)
if [ "$e4" -eq "$e3" ]; then ok "c4-restore-zero-processes"
else bad "c4-restore-zero-processes: $((e4 - e3)) new execs"; fi
if cmp -s "$BUILD/prog" "$TMP/prog.c3"; then ok "c4-binary-byte-identical"
else bad "c4-binary-byte-identical"; fi

# ---- criterion 5: comment-only header edit — dependents recompile, link cut off ----
# (drift mutation in pp — ROADMAP §2 milestone)
"$PP" --grant "fs:$SRC:rw" tests/mutate-cproject.pp -- append-comment "$SRC" shared.h \
  || { echo "FAIL mutate append-comment (pp)"; exit 1; }
l_before=$(links)
run "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
e5=$(execs); l_after=$(links)
if [ $((e5 - e4)) -eq "$TU" ] && [ $((l_after - l_before)) -eq 0 ]; then
  ok "c5-comment-edit-link-cutoff ($TU recompiles, 0 links)"
else bad "c5-comment-edit-link-cutoff: $((e5 - e4)) execs, $((l_after - l_before)) links (want $TU, 0)"; fi
grep -qE "create=0 update=0 delete=0" "$TMP/out" && ok "c5-outputs-unchanged" \
  || bad "c5-outputs-unchanged" "$(tail -3 "$TMP/out")"

# ---- criterion 7: authority gates hits — no process grant, nothing served ----
run --grant "fs:$SRC:ro" --grant "fs:$BUILD:wo" --reconcile "$BUILD" "$TMP/build.pp"
e7=$(execs)
if grep -qE "apability" "$TMP/out" && [ "$e7" -eq "$e5" ]; then
  ok "c7-no-grant-no-hit-no-exec"
else bad "c7-no-grant-no-hit-no-exec" "$(tail -3 "$TMP/out")"; fi

# ---- VM parity: compile-node entries are shared cross-backend ----
lv_before=$(links)
run --bytecode "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
ev=$(execs); lv=$(links)
if [ $((ev - e5)) -le 1 ] && [ $((lv - lv_before)) -le 1 ]; then
  ok "vm-shares-compile-cache ($((ev - e5)) execs — at most its own link)"
else bad "vm-shares-compile-cache: $((ev - e5)) new execs"; fi
run --bytecode "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp"
ev2=$(execs)
if [ "$ev2" -eq "$ev" ]; then ok "vm-null-zero-processes"
else bad "vm-null-zero-processes: $((ev2 - ev)) new execs"; fi

# ---- Phase 3 exit criterion 1 (docs/PLAN-phase3-parallel.md): the same
# 101-TU build, cold, under --schedule parallel:N vs serial (the DEFAULT —
# byte-identical program text, only the CLI flag differs): same desired-
# state hash, same materialized tree bytes, same cold exec count, measured
# speedup. Uses fresh store + build dirs so it doesn't disturb the
# criteria above; SRC is whatever this file's earlier mutations left it
# (still 101 TUs — the counts below don't depend on file CONTENTS). ----
NPROC=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
BUILD_S="$TMP/build-serial"
BUILD_P="$TMP/build-parallel"
GS=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_S:wo" --grant process)
GP=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_P:wo" --grant process)

rm -rf "$TMP/.pp" "$BUILD_S"
t0=$(now_ms)
run "${GS[@]}" --reconcile "$BUILD_S" "$TMP/build.pp"
t1=$(now_ms)
serial_ms=$((t1 - t0))
es=$(execs)
if [ "$es" -eq $((TU + 1)) ]; then ok "p3-serial-cold-exec-count ($es)"
else bad "p3-serial-cold-exec-count: expected $((TU + 1)), got $es" "$(tail -5 "$TMP/out")"; fi

rm -rf "$TMP/.pp" "$BUILD_P"
t0=$(now_ms)
run "${GP[@]}" --schedule "parallel:$NPROC" --reconcile "$BUILD_P" "$TMP/build.pp"
t1=$(now_ms)
parallel_ms=$((t1 - t0))
ep=$(execs)
if [ "$ep" -eq $((TU + 1)) ]; then ok "p3-parallel-cold-exec-count ($ep)"
else bad "p3-parallel-cold-exec-count: expected $((TU + 1)), got $ep" "$(tail -5 "$TMP/out")"; fi

if [ -x "$BUILD_P/prog" ] && "$BUILD_P/prog"; then ok "p3-parallel-binary-runs"
else bad "p3-parallel-binary-runs"; fi

if diff -rq "$BUILD_S" "$BUILD_P" > /tmp/p3-tree-diff.out 2>&1; then
  ok "p3-same-tree-bytes (recursive cmp, parallel:$NPROC workers)"
else
  bad "p3-same-tree-bytes" "$(cat /tmp/p3-tree-diff.out)"
fi

echo "     [timing] serial=${serial_ms}ms parallel:$NPROC=${parallel_ms}ms"
if [ "$parallel_ms" -lt "$serial_ms" ]; then
  ok "p3-parallel-faster-than-serial (${parallel_ms}ms < ${serial_ms}ms)"
else
  bad "p3-parallel-faster-than-serial: ${parallel_ms}ms not < ${serial_ms}ms (single-core CI runner?)"
fi

# Null rebuild under parallel: zero new execs.
run "${GP[@]}" --schedule "parallel:$NPROC" --reconcile "$BUILD_P" "$TMP/build.pp"
ep_null=$(execs)
if [ "$ep_null" -eq "$ep" ]; then ok "p3-parallel-null-zero-execs"
else bad "p3-parallel-null-zero-execs: $((ep_null - ep)) new execs"; fi

# Same desired-state hash: the store is now fully warm (the null rebuild
# above just replayed hits), so --check's schedule-transparency audit
# (main.ml) re-runs the program forced Serial against this SAME store and
# compares Types.hash_value of the desired-state value — all hits, so this
# adds no execs and exercises exactly LAW 34/35's "schedule is result-
# transparent" promise, not the (unrelated) LAW 38 per-node volatility
# double-run (which only triggers on a Miss).
run "${GP[@]}" --schedule "parallel:$NPROC" --check --reconcile "$BUILD_P" "$TMP/build.pp"
ep_check=$(execs)
if [ "$ep_check" -eq "$ep" ] && ! grep -q "schedule non-transparent" "$TMP/out"; then
  ok "p3-same-desired-state-hash (schedule-transparency audit passed, 0 new execs)"
else
  bad "p3-same-desired-state-hash" "$(tail -5 "$TMP/out")"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PHASE-1 EXIT CRITERIA TEST PASSED ==="; fi
exit $fail
