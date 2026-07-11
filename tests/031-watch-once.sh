#!/usr/bin/env bash
# Phase 2: --watch / --once watch mode foundation, pp graph.
#
#   Exit criterion 3: --once provisions once and terminates.
#   Exit criterion 4: --watch and --once hit the same node keys in the same store.
#   Introspection: pp graph prints the cell-node dependency graph from traces.
#
#   --watch uses a polling pull-in-loop: each iteration clears in-memory state
#   and re-runs from the root; the persistent store's trace verification
#   naturally skips unchanged nodes (hits) and recomputes changed ones (misses),
#   proving the store-level collapse between one-shot and watch modes.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

# Portable `timeout`: macOS ships without coreutils. Must be a real executable,
# not a shell function — `timeout N cmd &` has to put cmd's own pid in $! so
# `kill $!` reaches it (alarm(2) survives the exec chain).
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent  (matches named file or $TMP/out)
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- content ---"; cat "$file"; fail=1; fi
}

assert_count() {  # NAME PATTERN EXPECTED-COUNT FILE
  # Watch iterations land asynchronously: poll (bounded) until the count
  # arrives instead of trusting a fixed sleep, then assert exactness.
  local name="$1" pat="$2" want="$3" file="$4"
  local got="" i=0
  while [ "$i" -lt 100 ]; do
    got=$(grep -c "$pat" "$file" 2>/dev/null || printf "0")
    [ "$got" = "$want" ] && break
    sleep 0.1; i=$((i + 1))
  done
  if [ "$got" = "$want" ]; then echo "ok   $name"
  else echo "FAIL $name: expected $pat count $want, got $got"
       echo "--- content ---"; cat "$file"; fail=1; fi
}

# Build a simple two-node program: compile reads a.c, link depends on compile.
cat > "$TMP/build.pp" <<EOF
(let [obj (force (node (do (perform log "COMPILE")
                           (do (slurp "$TMP/a.c")))))]
  (perform log (force (node (do (perform log "LINK")
                                (string-append "linked:" obj))))))
EOF
echo "V1" > "$TMP/a.c"

# --- (a) --once terminates after one run ---
rm -rf "$TMP/.pp"
timeout 5 "$PP" --once --grant "fs:$TMP:ro" "$TMP/build.pp" > "$TMP/out" 2>&1
RC=$?
[ $RC -eq 0 ] && echo "ok   once-exit" || { echo "FAIL once-exit: exit $RC"; cat "$TMP/out"; fail=1; }
assert "once-compile" "\\[info\\] COMPILE" present
assert "once-link"    "\\[info\\] LINK"    present

# --- (b) --watch re-runs when a file changes ---
    rm -rf "$TMP/.pp"
    # Start watch in background with a generous timeout
    timeout 25 "$PP" --watch --watch-interval 0.3 --grant "fs:$TMP:ro" \
      "$TMP/build.pp" > "$TMP/watch-out" 2>&1 &
    WATCH_PID=$!
    # Let first iteration complete
    sleep 4
    sync
    # First run: COMPILE and LINK each logged once
    assert_count "watch-first-compile" "COMPILE" 1 "$TMP/watch-out"
    assert_count "watch-first-link"    "LINK"    1 "$TMP/watch-out"
    # Change the source file
    echo "V2" > "$TMP/a.c"
    # Wait for poll cycle + re-evaluation
    sleep 4
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
HOME="$TMP" timeout 4 "$PP" why --watch --watch-interval 0.3 \
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
timeout 12 "$PP" --watch --watch-interval 0.3 --grant "fs:$TMP:ro" \
  "$TMP/build.pp" > "$TMP/watch-build-out" 2>&1 &
WATCH_PID=$!
sleep 4
sync
assert_count "build-watch-first" "COMPILE" 1 "$TMP/watch-build-out"
echo "W2" > "$TMP/a.c"
sleep 4
assert_count "build-watch-second" "COMPILE" 2 "$TMP/watch-build-out"
kill $WATCH_PID 2>/dev/null
wait $WATCH_PID 2>/dev/null || true
rm -rf "$TMP/.pp"
# Program that returns a desired-state map
cat > "$TMP/reconcile.pp" <<EOF
{"file.txt" (slurp "$TMP/a.c")}
EOF
echo "RECONCILE-CONTENT" > "$TMP/a.c"
OUTROOT="$TMP/outroot"
mkdir -p "$OUTROOT"
HOME="$TMP" "$PP" --once --grant "fs:$OUTROOT:rw" --grant "fs:$TMP:ro" --reconcile "$OUTROOT" \
  "$TMP/reconcile.pp" > "$TMP/rec-out" 2>&1
assert "once-reconcile-create" "create=1" present "$TMP/rec-out"
[ -f "$OUTROOT/file.txt" ] && echo "ok   once-reconcile-file" \
  || { echo "FAIL once-reconcile-file: missing"; fail=1; }

exit $fail
