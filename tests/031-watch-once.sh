#!/usr/bin/env bash
# --watch / --once watch mode foundation, pp graph.
#
#   --once provisions once and terminates.
#   --watch and --once hit the same node keys in the same store.
#   Introspection: pp graph prints the cell-node dependency graph from traces.
#
#   --watch uses a polling pull-in-loop: each iteration clears in-memory state
#   and re-runs from the root; the persistent store's trace verification
#   naturally skips unchanged nodes (hits) and recomputes changed ones (misses),
#   proving the store-level collapse between one-shot and watch modes.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# Portable `timeout`: macOS ships without coreutils. Must be a real executable,
# not a shell function — `timeout N cmd &` has to put cmd's own pid in $! so
# `kill $!` reaches it (alarm(2) survives the exec chain).
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

# assert_count (poll-until-count) lives in lib.sh — this suite was where that
# idiom started. `assert` stays local: its present/absent shape is specific.
assert() {  # NAME PATTERN present|absent  (matches named file or $TMP/out)
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- content ---"; cat "$file"; fail=1; fi
}

# Build a simple two-node program: compile reads a.c, link depends on compile.
cat > "$TMP/build.pp" <<EOF
let (obj = force(node {
  perform log("COMPILE")
  do { slurp("$TMP/a.c") }
})) {
  perform log(force(node {
    perform log("LINK")
    string-append("linked:", obj)
  }))
}
EOF
echo "V1" > "$TMP/a.c"

# --- (a) --once terminates after one run ---
rm -rf "$TMP/.pp"
timeout -k 5 5 "$PP" --once --grant "fs:$TMP:ro" "$TMP/build.pp" > "$TMP/out" 2>&1
RC=$?
[ $RC -eq 0 ] && echo "ok   once-exit" || { echo "FAIL once-exit: exit $RC"; cat "$TMP/out"; fail=1; }
assert "once-compile" "\\[info\\] COMPILE" present
assert "once-link"    "\\[info\\] LINK"    present

# --- (b) --watch re-runs when a file changes ---
    rm -rf "$TMP/.pp"
    # Start watch in background with a generous timeout
    timeout -k 5 25 "$PP" --watch --watch-interval 0.3 --grant "fs:$TMP:ro" \
      "$TMP/build.pp" > "$TMP/watch-out" 2>&1 &
    WATCH_PID=$!
    # First run: COMPILE and LINK each logged once (assert_count polls until
    # the cold iteration lands — no fixed sleep).
    assert_count "watch-first-compile" "COMPILE" 1 "$TMP/watch-out"
    assert_count "watch-first-link"    "LINK"    1 "$TMP/watch-out"
    # Change the source file; the poller waits for the re-evaluation to arrive.
    echo "V2" > "$TMP/a.c"
    # Second run: COMPILE and LINK each logged a second time
    assert_count "watch-second-compile" "COMPILE" 2 "$TMP/watch-out"
    assert_count "watch-second-link"    "LINK"    2 "$TMP/watch-out"
# Kill the watch process
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true

# --- (c) --once and --watch share the same store keys ---
rm -rf "$TMP/.pp"
HOME="$TMP" "$PP" why --grant "fs:$TMP:ro" "$TMP/build.pp" 2> "$TMP/why-once" 1>/dev/null
ONCE_KEYS=$(grep -oE 'node [0-9a-f]+' "$TMP/why-once" | sort -u)
[ -n "$ONCE_KEYS" ] || { echo "FAIL same-keys: no keys in --once why output"; cat "$TMP/why-once"; fail=1; }

rm -rf "$TMP/.pp"
HOME="$TMP" timeout -k 5 2 "$PP" why --watch --watch-interval 0.3 \
  --grant "fs:$TMP:ro" "$TMP/build.pp" 2> "$TMP/why-watch" 1>/dev/null || true
WATCH_KEYS=$(grep -oE 'node [0-9a-f]+' "$TMP/why-watch" | sort -u)
[ -n "$WATCH_KEYS" ] || { echo "FAIL same-keys: no keys in --watch why output"; cat "$TMP/why-watch"; fail=1; }

if [ "$ONCE_KEYS" = "$WATCH_KEYS" ]; then echo "ok   same-keys"
else echo "FAIL same-keys: once='$ONCE_KEYS' watch='$WATCH_KEYS'"; fail=1; fi

# --- (d) pp graph shows cell->node edges ---
rm -rf "$TMP/.pp"
HOME="$TMP" "$PP" --grant "fs:$TMP:ro" "$TMP/build.pp" > /dev/null 2>&1
HOME="$TMP" "$PP" --grant "fs:$TMP:ro" graph "$TMP/build.pp" > "$TMP/graph-out" 2>&1
assert "graph-has-cell"   "file:"   present "$TMP/graph-out"
assert "graph-has-arrow"  "→"       present "$TMP/graph-out"
assert "graph-has-nodes"  "node\\(s\\)" present "$TMP/graph-out"

# --- (e) --watch without --reconcile still works (build watch) ---
rm -rf "$TMP/.pp"
echo "W1" > "$TMP/a.c"
timeout -k 5 60 "$PP" --watch --watch-interval 0.3 --grant "fs:$TMP:ro" \
  "$TMP/build.pp" > "$TMP/watch-build-out" 2>&1 &
WATCH_PID=$!
assert_count "build-watch-first" "COMPILE" 1 "$TMP/watch-build-out"
echo "W2" > "$TMP/a.c"
assert_count "build-watch-second" "COMPILE" 2 "$TMP/watch-build-out"
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true

# --- (f) one process, two evaluations: evaluator state is rebuilt while the
# persistent store remains available. Macro definitions and gensym names are
# source-derived, so the second evaluation must not inherit the first one's
# macro or counter; dynamic config and handlers must unwind at the boundary. ---
rm -rf "$TMP/.pp"
cat > "$TMP/lifecycle.pp" <<EOF
defmacro stale(x) { 1 }
print(string-trim(slurp("$TMP/lifecycle-phase")))
print(stale(7))
print(gensym("g"))
with-config({:mode -> "scoped"}) { print(config(:mode, "default")) }
with-handler(log = fn(x) { print("handled", x) }) { perform log("first") }
EOF
printf 'one\n' > "$TMP/lifecycle-phase"
timeout -k 5 60 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP:ro" \
  "$TMP/lifecycle.pp" > "$TMP/lifecycle-out" 2> "$TMP/lifecycle-err" &
WATCH_PID=$!
new_watch_pass "evaluation-one" '^"one"$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-one-macro" '^1$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-one-gensym" '^g~1$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-one-config" '^"scoped"$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-one-handler" '^"handled""first"$' 1 "$TMP/lifecycle-out"

cat > "$TMP/lifecycle.pp" <<EOF
def stale(x) { 9 }
print(string-trim(slurp("$TMP/lifecycle-phase")))
print(stale(7))
print(gensym("g"))
print(config(:mode, "default"))
perform log("second")
EOF
printf 'two\n' > "$TMP/lifecycle-phase"
new_watch_pass "evaluation-two" '^"two"$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-two-function-not-macro" '^9$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-two-gensym-reset" '^g~1$' 2 "$TMP/lifecycle-out"
new_watch_pass "evaluation-two-config-reset" '^"default"$' 1 "$TMP/lifecycle-out"
new_watch_pass "evaluation-two-handler-reset" '^\[info\] second$' 1 "$TMP/lifecycle-err"
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true

# Observations are rebuilt from the current source on a new evaluation. After
# the second source stops reading `obsolete`, changing that old cell must not
# cause a third watch pass.
rm -rf "$TMP/.pp"
printf 'one\n' > "$TMP/observation-phase"
printf 'old-one\n' > "$TMP/obsolete"
cat > "$TMP/observations-one.pp" <<EOF
print(string-trim(slurp("$TMP/observation-phase")))
print(string-trim(slurp("$TMP/obsolete")))
EOF
cat > "$TMP/observations-two.pp" <<EOF
print(string-trim(slurp("$TMP/observation-phase")))
EOF
timeout -k 5 60 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP:ro" \
  "$TMP/observations-one.pp" > "$TMP/observations-out" 2> "$TMP/observations-err" &
WATCH_PID=$!
new_watch_pass "observations-evaluation-one" '^"old-one"$' 1 "$TMP/observations-out"
cp "$TMP/observations-two.pp" "$TMP/observations-one.pp"
printf 'two\n' > "$TMP/observation-phase"
new_watch_pass "observations-evaluation-two" '^"two"$' 1 "$TMP/observations-out"
printf 'old-two\n' > "$TMP/obsolete"
assert_count_stable "observations-reset-at-evaluation" '^"two"$' 1 "$TMP/observations-out"
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true

# Source-derived registry entries do not survive a new evaluation. The second
# watch pass intentionally fails while looking up the probe/domain entry that
# only the first source registered.
rm -rf "$TMP/.pp"
cat > "$TMP/registry-one.pp" <<EOF
register-probe("stale", fn() { 1 }, cap-none())
print(string-trim(slurp("$TMP/registry-phase")))
print(probe("stale"))
EOF
cat > "$TMP/registry-two.pp" <<EOF
print(string-trim(slurp("$TMP/registry-phase")))
print(probe("stale"))
EOF
printf 'one\n' > "$TMP/registry-phase"
timeout -k 5 60 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP:ro" \
  "$TMP/registry-one.pp" \
  > "$TMP/registry-out" 2> "$TMP/registry-err" &
WATCH_PID=$!
new_watch_pass "registry-evaluation-one" '^1$' 1 "$TMP/registry-out"
cp "$TMP/registry-two.pp" "$TMP/registry-one.pp"
printf 'two\n' > "$TMP/registry-phase"
wait_for 30 grep -q 'no such probe registered: stale' "$TMP/registry-err" \
  && ok "registry-evaluation-two-resets-probe-domain" \
  || bad "registry-evaluation-two-resets-probe-domain" "$(cat "$TMP/registry-err")"
wait $WATCH_PID 2>/dev/null || true

# --- (g) probe values and sealed pins are per-watch-pass, not per command ---
rm -rf "$TMP/.pp"
mkdir -p "$TMP/world"
printf '1\n' > "$TMP/world/counter"
printf 'aa\n' > "$TMP/secret"
cat > "$TMP/pass-state.pp" <<EOF
register-probe("counter", fn() {
  string-trim(slurp("$TMP/world/counter"))
}, cap-restrict(current-capabilities(), "$TMP/world/counter", :ro))
print(probe("counter"))
print(probe("counter"))
print(string-length(unseal(slurp("$TMP/secret"))))
EOF
timeout -k 5 60 "$PP" --watch --watch-interval 0.1 --grant "fs:$TMP/world:ro" \
  --grant "secret:$TMP/secret" "$TMP/pass-state.pp" \
  > "$TMP/pass-state-out" 2> "$TMP/pass-state-err" &
WATCH_PID=$!
new_watch_pass "pass-one-probe-value" '^"1"$' 2 "$TMP/pass-state-out"
new_watch_pass "pass-one-sealed-length" '^3$' 1 "$TMP/pass-state-out"
printf '2\n' > "$TMP/world/counter"
printf 'bbbb\n' > "$TMP/secret"
new_watch_pass "pass-two-probe-value" '^"2"$' 2 "$TMP/pass-state-out"
new_watch_pass "pass-two-sealed-length" '^5$' 1 "$TMP/pass-state-out"
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true

rm -rf "$TMP/.pp"
# Program that returns a canonical desired tree.
cat > "$TMP/reconcile.pp" <<EOF
{:tree -> {"file.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob(slurp("$TMP/a.c"))}}}
EOF
echo "RECONCILE-CONTENT" > "$TMP/a.c"
OUTROOT="$TMP/outroot"
mkdir -p "$OUTROOT"
HOME="$TMP" new_evaluation --grant "fs:$OUTROOT:rw" --grant "fs:$TMP:ro" --reconcile "$OUTROOT" \
  "$TMP/reconcile.pp" > "$TMP/rec-out" 2>&1
assert "once-reconcile-create" "create=1" present "$TMP/rec-out"
[ -f "$OUTROOT/file.txt" ] && echo "ok   once-reconcile-file" \
  || { echo "FAIL once-reconcile-file: missing"; fail=1; }

exit $fail
