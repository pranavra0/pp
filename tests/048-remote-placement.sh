#!/usr/bin/env bash
# Remote placement: --schedule remote:<member> dispatches data-closed
# node bodies to another cluster member over the same transport as
# tests/047-cluster-sync.sh.
#
# Two SIMULATED cluster members are two `pp` process invocations differing
# only in $HOME (Store.store_root is a process-wide singleton — same CI
# loopback shape tests/047 already uses); a "cluster member" (NODEB) is
# addressed via ~/.pp/cluster/members on the dispatcher (NODEA), never
# --grant. src/remote.ml is the implementation; internal seams
# (--remote-node, PP_REMOTE_TEST_HOOK[_AFTER]) are exercised directly here,
# the way tests/047 drives --serve-hit/--recv-hit directly.
#
# WALL (found building this test, reported as a known limitation, NOT
# fixed here): `--reconcile` unconditionally preloads stdlib/list.pp as
# domain glue (main.ml's stdlib_glue_sources), and list.pp defines its OWN
# pp-level `(def (map f lst) ...)`, which shadows the batching-aware `map`
# builtin — the one primitive that can build a compound value without
# forcing its elements. Once shadowed, `(map compile names)` recurses
# through `cons`, whose argument-forcing on application forces each node
# inline as list.pp's `map` builds each cons cell — the exact "pairing
# trap" tests/024's own build.pp comment warns against, just entered from
# a different direction. This silently defeats collect_unevaluated_nodes
# for EVERY non-serial scheduling policy (parallel/race, and now remote)
# whenever a build uses `--reconcile` — verified directly (a --schedule
# parallel:3 --reconcile run of 3 slow nodes executes them strictly one
# at a time, zero forking, collect_unevaluated_nodes always `[]`).
# tests/024's own parallel exit criterion never caught this because its
# assertions are exec-COUNT (identical either way) plus a SOFT timing
# check that already accepts "no speedup, not pathological" as a pass. This
# test therefore does NOT use `--reconcile` for the N-TU build below —
# materialization is done directly (plain top-level `write-file` calls,
# outside any node body, into a granted :wo/:rw dir) so it exercises the
# scheduler correctly. A real fix (list.pp not shadowing `map`, or
# reconcile-glue not force-loading it) is tracked separately from remote
# placement.
#
#   T6      — an N-TU real-cc build under --schedule remote:B: byte-
#             identical desired-state hash + materialized tree vs serial.
#   cross-machine hit — a data-closed compile node forced on the member
#             produces a trace the dispatcher hits (no local recompute).
#   pinned bytes, not live disk — a shared data file that DIFFERS, at the
#             moment the member actually runs, from what the dispatcher
#             pre-observed/pinned: the member's result reflects the
#             dispatcher's PINNED bytes, never its own current disk.
#   non-data-closed — a node whose free var is a closure stays local; no
#             remote dispatch attempted at all (member's store untouched).
#   unreachable member — a bad members-file target degrades to local
#             compute; the build still succeeds with the correct result.
#   tool: not pre-seeded — the member's own `cc` legitimately runs (a
#             member always makes its own local observations), proven via
#             ITS journal.
#   VM parity — the same remote build under --bytecode.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# ===========================================================================
# Part 1: an N-TU real-cc build, dispatcher (A) + member (B), local-dir loopback
# ===========================================================================
command -v cc >/dev/null 2>&1 || { echo "=== 048 REMOTE-PLACEMENT: cc-dependent part SKIPPED (no cc) ==="; }

if command -v cc >/dev/null 2>&1; then
  NODEA="$TMP/nodeA"; NODEB="$TMP/nodeB"
  mkdir -p "$NODEA" "$NODEB/.pp/cluster"
  SRC="$TMP/src"; mkdir -p "$SRC"
  N=8; TU=$((N + 1))

  HOME="$NODEA" "$PP" cluster-init > "$TMP/out" 2>&1
  cp "$NODEA/.pp/cluster/secret" "$NODEA/.pp/cluster/id" "$NODEB/.pp/cluster/"
  echo "B $NODEB/.pp/store" > "$NODEA/.pp/cluster/members"

  "$PP" --grant "fs:$SRC:rw" tests/gen-cproject.pp -- "$N" "$SRC" 2>"$TMP/gen.err" \
    || { echo "FAIL fixture-generator (pp)"; cat "$TMP/gen.err"; exit 1; }

  cat > "$TMP/build.pp" <<EOF
def each(f, lst) { if nil?(lst) { nil } else { f(car(lst)); each(f, cdr(lst)) } }
def foldl2(f, acc, lst) { if nil?(lst) { acc } else { foldl2(f, f(acc, car(lst)), cdr(lst)) } }
def zip2(lst1, lst2) {
  if nil?(lst1) { nil } else {
    cons(cons(car(lst1), car(lst2)), zip2(cdr(lst1), cdr(lst2))) } }
def compile(name) {
  node {
    perform run-dep!(string-append(name, ".d"), "cc", "-MD", "-MF", string-append(name, ".d"), "-O0", "-c", string-append("$SRC/", string-append(name, ".c")), "-o", string-append(name, ".o"))
    blob(slurp(string-append(name, ".o")))
  }
}


def link(objs) {
  force(node { each(
fn(o) { perform write-file(string-append(car(o), ".o"), blob-get(cdr(o))) }, objs)
    do {
      perform write-file("link.d", "prog: ")
      do {
        perform run-dep!("link.d", "sh", "-c", string-append("cc -o prog ", foldl2(
fn(acc, o) { string-append(acc, string-append(car(o), ".o ")) }, "", objs)))
        blob(slurp("prog"))
      }
    } }) }
# Materialize DIRECTLY — plain top-level write-file calls (outside any
# node body, absolute paths, capability-checked) into \$BUILD — rather
# than via --reconcile's fs domain, which would preload stdlib/list.pp
# and shadow the batching \`map\` builtin (the WALL noted at the top of
# this file). \$BUILD must already exist (this test's shell creates it).
let (names = string-split(slurp("$SRC/sources.txt"), "\n")) {
  let (results = force-deep(map(compile, names))) {
    let (objs = zip2(names, results)) {
      let (prog = link(objs)) {
        each(
fn(o) {
          perform write-file(string-append("\$BUILD/", string-append(car(o), ".o")), blob-get(cdr(o)))
        }, objs)
        perform write-file(string-append("\$BUILD/prog"), blob-get(prog))
        perform run("chmod", "+x", string-append("\$BUILD/prog"))
      }
    }
  }
}
EOF
  # \$BUILD is a per-run placeholder the shell fills in below (each cold
  # build gets its own BUILD dir, so the SAME build.pp text is reused
  # byte-for-byte across serial/remote/degrade/vm runs). The node key is a
  # hash of code plus argument values (SPEC law 20), so identical source
  # text is required for the byte-identical comparison below (case T6); a
  # literal path baked in per-run would change the program's hash between
  # runs for no reason.

  BUILD_S="$TMP/build-serial"; BUILD_R="$TMP/build-remote"
  mkdir -p "$BUILD_S" "$BUILD_R"
  build_pp_for() {  # BUILD_DIR -> writes $TMP/build.pp with $BUILD substituted
    sed "s#\\\$BUILD#$1#g" "$TMP/build.pp.tmpl" > "$TMP/build.pp"
  }
  mv "$TMP/build.pp" "$TMP/build.pp.tmpl"

  GS=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_S:rw" --grant process)
  GR=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_R:rw" --grant process)

  # ---- cold serial build (the reference) ----
  rm -rf "$NODEA/.pp/store"
  build_pp_for "$BUILD_S"
  HOME="$NODEA" "$PP" "${GS[@]}" "$TMP/build.pp" > "$TMP/serial.out" 2>&1
  if [ -x "$BUILD_S/prog" ] && "$BUILD_S/prog"; then ok "serial-binary-runs"
  else bad "serial-binary-runs" "$(tail -5 "$TMP/serial.out")"; fi

  # ---- cold remote build: dispatcher A, member B ----
  rm -rf "$NODEA/.pp/store"
  # NODEB's own store carries over from any earlier scenario in this file;
  # start it cold too so "member forced the compile nodes" below is
  # unambiguous (a stale hit from a PRIOR test's key would look identical).
  rm -rf "$NODEB/.pp/store"
  build_pp_for "$BUILD_R"
  HOME="$NODEA" "$PP" "${GR[@]}" --schedule remote:B "$TMP/build.pp" \
    > "$TMP/remote.out" 2>&1
  if [ -x "$BUILD_R/prog" ] && "$BUILD_R/prog"; then ok "remote-binary-runs"
  else bad "remote-binary-runs" "$(tail -8 "$TMP/remote.out")"; fi

  # Materialized tree is byte-identical, serial vs remote (case T6 below).
  if diff -rq "$BUILD_S" "$BUILD_R" > "$TMP/tree-diff.out" 2>&1; then
    ok "T6-same-tree-bytes (serial vs remote:B)"
  else
    bad "T6-same-tree-bytes" "$(cat "$TMP/tree-diff.out")"
  fi

  # Desired-state hash is byte-identical, serial vs remote (case T6
  # below). --check re-runs the SAME program forced Serial against the
  # SAME (now-warm) store and compares Types.hash_value of the
  # desired-state value (main.ml's existing schedule-transparency audit,
  # extended to Remote by policy_name); a mismatch would print "schedule
  # non-transparent" and fail the audit.
  HOME="$NODEA" "$PP" "${GR[@]}" --schedule remote:B --check "$TMP/build.pp" \
    > "$TMP/check.out" 2>&1
  CODE=$?
  if [ "$CODE" -eq 0 ] && ! grep -q "schedule non-transparent" "$TMP/check.out"; then
    ok "T6-same-desired-state-hash (--check schedule-transparency audit)"
  else
    bad "T6-same-desired-state-hash" "exit=$CODE" "$(tail -8 "$TMP/check.out")"
  fi

  # ---- cross-machine hit: the member actually forced compile nodes, and
  # the dispatcher's own store now carries at least one trace key the
  # member's store ALSO carries (a genuine cross-machine hit, not merely
  # "both happened to build the same project independently"). ----
  A_KEYS=$(ls "$NODEA/.pp/store/traces" 2>/dev/null | sort)
  B_KEYS=$(ls "$NODEB/.pp/store/traces" 2>/dev/null | sort)
  COMMON=$(comm -12 <(echo "$A_KEYS") <(echo "$B_KEYS") | grep -c .)
  if [ "${COMMON:-0}" -gt 0 ]; then
    ok "cross-machine-hit ($COMMON shared trace key(s) between A and B)"
  else
    bad "cross-machine-hit: no trace keys shared between dispatcher and member" \
      "A has $(echo "$A_KEYS" | grep -c .) keys, B has $(echo "$B_KEYS" | grep -c .) keys"
  fi
  if grep -qE "^exec " "$NODEB/.pp/store/journal/log" 2>/dev/null; then
    ok "tool-not-preseeded (member's own journal shows it really ran cc itself)"
  else
    bad "tool-not-preseeded: member journal has no exec lines (did it run at all?)"
  fi

  # ---- null rebuild under remote: no new COMPILE/LINK execs (fully warm
  # store; the --check run above already re-verified everything). This
  # test's own materialization (a plain top-level `chmod +x`, chosen to
  # avoid --reconcile's list.pp-shadowing WALL above) is not node-cached
  # and legitimately re-execs every invocation — expect exactly that one
  # constant exec, not the (N+1) cc/link execs a cache miss would add. ----
  before=$(grep -c "^exec " "$NODEA/.pp/store/journal/log" 2>/dev/null || echo 0)
  HOME="$NODEA" "$PP" "${GR[@]}" --schedule remote:B "$TMP/build.pp" \
    > "$TMP/null.out" 2>&1
  after=$(grep -c "^exec " "$NODEA/.pp/store/journal/log" 2>/dev/null || echo 0)
  if [ "$((after - before))" -eq 1 ]; then ok "remote-null-rebuild-no-new-compile-link-execs (only chmod re-ran)"
  else bad "remote-null-rebuild-no-new-compile-link-execs: $((after - before)) new execs (want 1: chmod only)" "$(tail -5 "$TMP/null.out")"; fi

  # ---- member-unreachable: build still succeeds, degrades to local. ----
  BUILD_D="$TMP/build-degrade"; mkdir -p "$BUILD_D"
  rm -rf "$NODEA/.pp/store"
  echo "B /this/path/does/not/exist/.pp/store" > "$NODEA/.pp/cluster/members"
  GD=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_D:rw" --grant process)
  build_pp_for "$BUILD_D"
  HOME="$NODEA" "$PP" "${GD[@]}" --schedule remote:B "$TMP/build.pp" \
    > "$TMP/degrade.out" 2>&1
  if [ -x "$BUILD_D/prog" ] && "$BUILD_D/prog"; then ok "unreachable-member-degrades-build-succeeds"
  else bad "unreachable-member-degrades-build-succeeds" "$(tail -8 "$TMP/degrade.out")"; fi
  if diff -rq "$BUILD_S" "$BUILD_D" > "$TMP/tree-diff2.out" 2>&1; then
    ok "unreachable-member-same-tree-bytes"
  else bad "unreachable-member-same-tree-bytes" "$(cat "$TMP/tree-diff2.out")"; fi
  echo "B $NODEB/.pp/store" > "$NODEA/.pp/cluster/members"

  # ---- VM parity: the same remote build under --bytecode. ----
  BUILD_V="$TMP/build-vm"; mkdir -p "$BUILD_V"
  rm -rf "$NODEA/.pp/store" "$NODEB/.pp/store"
  GV=(--grant "fs:$SRC:ro" --grant "fs:$BUILD_V:rw" --grant process)
  build_pp_for "$BUILD_V"
  HOME="$NODEA" "$PP" --bytecode "${GV[@]}" --schedule remote:B "$TMP/build.pp" \
    > "$TMP/vm.out" 2>&1
  if [ -x "$BUILD_V/prog" ] && "$BUILD_V/prog"; then ok "vm-parity-binary-runs"
  else bad "vm-parity-binary-runs" "$(tail -8 "$TMP/vm.out")"; fi
  if diff -rq "$BUILD_S" "$BUILD_V" > "$TMP/tree-diff3.out" 2>&1; then
    ok "vm-parity-same-tree-bytes"
  else bad "vm-parity-same-tree-bytes" "$(cat "$TMP/tree-diff3.out")"; fi
fi

# ===========================================================================
# Part 2: the member must observe the DISPATCHER's pinned bytes, never
# its own (possibly-drifted) disk, for a pre-seeded cell. Uses the
# PP_REMOTE_TEST_HOOK[_AFTER] seam (src/remote.ml) to force a deterministic
# window a real dispatcher/member network round-trip would occupy anyway:
# HOOK runs right after the dispatcher pushes pins (bytes = "V1") but
# before the member is spawned — mutates the SHARED file to "V2", so if
# the member observed its own disk instead of the pin it would read "V2".
# HOOK_AFTER runs once the member has exited (reverting to "V1") so the
# dispatcher's OWN post-pull Store.hit re-validation (against the CURRENT
# world, same as any local hit) also agrees, proving a full clean hit on
# the DISPATCHER's original bytes, not a fluke of timing.
# ===========================================================================
NODEC="$TMP/nodeC"; NODED="$TMP/nodeD"
mkdir -p "$NODEC" "$NODED/.pp/cluster"
HOME="$NODEC" "$PP" cluster-init > "$TMP/out" 2>&1
cp "$NODEC/.pp/cluster/secret" "$NODEC/.pp/cluster/id" "$NODED/.pp/cluster/"
echo "D $NODED/.pp/store" > "$NODEC/.pp/cluster/members"

WORK="$TMP/q11-work"; mkdir -p "$WORK"
printf 'V1\n' > "$WORK/data.txt"
cat > "$TMP/q11.pp" <<EOF
def mk(name) { node { slurp(string-append("$WORK/", name)) } }
car(force-deep(map(mk, list("data.txt"))))
EOF

export PP_REMOTE_TEST_HOOK="printf 'V2\n' > $WORK/data.txt"
export PP_REMOTE_TEST_HOOK_AFTER="printf 'V1\n' > $WORK/data.txt"
HOME="$NODEC" "$PP" --why --grant "fs:$WORK:ro" --schedule remote:D "$TMP/q11.pp" \
  > "$TMP/q11.out" 2>&1
unset PP_REMOTE_TEST_HOOK PP_REMOTE_TEST_HOOK_AFTER

if grep -qE "hit — ok trace verified" "$TMP/q11.out"; then
  ok "Q11-bis-dispatcher-hit-after-revert (clean hit, not a recompute)"
else
  bad "Q11-bis-dispatcher-hit-after-revert" "$(cat "$TMP/q11.out")"
fi

# The member's OWN store object must be "V1\n" — the dispatcher's pinned
# bytes — even though the shared disk read "V2" at the exact moment the
# member's node body actually ran (proven by the hook ordering above): if
# the member had observed its own disk instead of the pin, its stored
# object would be "V2\n".
D_OBJ=$(for f in "$NODED"/.pp/store/objects/*; do cat "$f" 2>/dev/null; done)
if echo "$D_OBJ" | grep -q '"V1'; then
  ok "Q11-bis-member-used-pinned-bytes (member's object is V1, not disk's V2)"
else
  bad "Q11-bis-member-used-pinned-bytes" "member objects: $D_OBJ"
fi
if echo "$D_OBJ" | grep -q '"V2'; then
  bad "Q11-bis-member-never-stored-disk-bytes: member ALSO has a V2 object (own-disk leak)"
else
  ok "Q11-bis-member-never-stored-disk-bytes"
fi

# ===========================================================================
# Part 3: non-data-closed node (free var is a closure) stays local — no
# remote dispatch attempted at all.
# ===========================================================================
NODEE="$TMP/nodeE"; NODEF="$TMP/nodeF"
mkdir -p "$NODEE" "$NODEF/.pp/cluster"
HOME="$NODEE" "$PP" cluster-init > "$TMP/out" 2>&1
cp "$NODEE/.pp/cluster/secret" "$NODEE/.pp/cluster/id" "$NODEF/.pp/cluster/"
echo "F $NODEF/.pp/store" > "$NODEE/.pp/cluster/members"

cat > "$TMP/closure.pp" <<'EOF'
def mkclosure() { fn(x) { x + 1 } }
def mk(f) { node { f(41) } }
perform log(if car(force-deep(list(mk(mkclosure())))) = 42 { "OK" } else {
  "FAIL"
})
EOF
HOME="$NODEE" "$PP" --schedule remote:F "$TMP/closure.pp" > "$TMP/closure.out" 2>&1
if grep -q '\[info\] OK' "$TMP/closure.out"; then ok "non-data-closed-correct-result"
else bad "non-data-closed-correct-result" "$(cat "$TMP/closure.out")"; fi
NF_TRACES=$(ls "$NODEF/.pp/store/traces" 2>/dev/null | wc -l | tr -d ' ')
if [ "$NF_TRACES" -eq 0 ]; then ok "non-data-closed-member-never-touched (0 traces on F)"
else bad "non-data-closed-member-never-touched" "F has $NF_TRACES trace(s)"; fi

# Diagonal check: `remote` is a recognized --schedule value alongside
# serial/parallel:N/race:N.
if "$PP" --help 2>&1 | grep -q "remote:<member>"; then ok "diagonal-remote-in-help"
else bad "diagonal-remote-in-help"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== M5 STAGE B (REMOTE PLACEMENT) TEST PASSED ==="; fi
exit $fail
