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
cat > "$TMP/build.pp" <<EOF
(def (map2 f lst) (if (nil? lst) nil (cons (f (car lst)) (map2 f (cdr lst)))))
(def (each f lst) (if (nil? lst) nil (do (f (car lst)) (each f (cdr lst)))))
(def (foldl2 f acc lst) (if (nil? lst) acc (foldl2 f (f acc (car lst)) (cdr lst))))

(def (compile name)
  (force (node
    (do (perform run-dep (string-append name ".d")
          "cc" "-MD" "-MF" (string-append name ".d") "-O0" "-c"
          (string-append "$SRC/" (string-append name ".c"))
          "-o" (string-append name ".o"))
        (blob (slurp (string-append name ".o")))))))

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
  (let [objs (force-deep (map2 (fn (n) (cons n (compile n))) names))]
    (let [prog (link objs)]
      (foldl2 (fn (m o) (map-insert m (string-append (car o) ".o") (cdr o)))
              (map-insert (hash-map) "prog" (string-append prog ":x"))
              objs))))
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

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PHASE-1 EXIT CRITERIA TEST PASSED ==="; fi
exit $fail
