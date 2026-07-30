#!/usr/bin/env bash
# A probe is a named, deliberately nondeterministic input: nondeterminism
# must be declared (SPEC law 37), and a probe's volatility stays contained
# and in-memory only (SPEC law 38).
#
# A probe is registered once (`register-probe! name observe-fn read-cap`,
# script-tier) and read inside a node via `$probe(name)`. The observe-fn runs
# OUTSIDE the reading node's trace stack, under exactly the registered
# read-cap; the reading node records only a `probe:<name>` cell (hash of the
# observed value), via ordinary record_read — so the node caches and
# re-verifies exactly like a `file:` cell, except the "file" here is
# irreducibly nondeterministic (a counter script) rather than a real file.
#
# Two SEPARATE `pp` invocations exercise "the same probe cell changing across
# passes" for most of this suite: each run re-executes the whole program, so
# `register-probe!` re-registers, `$probe("counter")` re-evaluates the
# observe-fn fresh, and the node's stored trace is re-verified against
# whatever the counter says NOW. Section (6) below additionally proves the
# SAME mechanism live under one long-running `pp --watch` process: probe
# reads are ordinary session observations, so generic watch-loop polling picks up a
# changed probe cell with NO special-cased wiring.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

# Portable `timeout` (macOS ships without coreutils) — same shim as
# tests/031-watch-once.sh.
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

COUNTER="$TMP/counter.txt"

assert() {  # NAME PATTERN present|absent  [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  local got
  if grep -qE "$pat" "$file"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode in $file, got $got"
    echo "--- output ---"; cat "$file"; fail=1
  fi
}

# =====================================================================
# (1) basic register+read, cache/re-force across two runs
# =====================================================================
cat > "$TMP/prog.pp" <<EOF
register-probe!("counter",
fn() { string-trim(\$file("$COUNTER")) }, cap-restrict(current-capabilities(), "$COUNTER", :ro))

log!(force(node {
  log!("COMPUTE")
  \$probe("counter")
}))
EOF

run() { rm -f "$TMP/out"; "$PP" "$@" --grant "fs:$TMP:ro" "$TMP/prog.pp" > "$TMP/out" 2>&1; }

rm -rf "$TMP/.pp"

printf '1\n' > "$COUNTER"
run
assert "run1-cold-computes"      "COMPUTE"  present
assert "run1-value-1"            "\\[info\\] 1$" present

run
assert "run2-unchanged-hit"      "COMPUTE"  absent
assert "run2-value-1"            "\\[info\\] 1$" present

printf '2\n' > "$COUNTER"
run
assert "run3-changed-recomputes" "COMPUTE"  present
assert "run3-value-2"            "\\[info\\] 2$" present

printf '1\n' > "$COUNTER"
run
assert "run4-revert-hit"         "COMPUTE"  absent
assert "run4-value-1"            "\\[info\\] 1$" present

# =====================================================================
# (2) probe value never lands under ~/.pp/store's objects/traces — a probe
#     is re-evaluated every pass (the probe cache is in-memory-only,
#     cleared per pass; there is no separate "probe cache" on disk the way
#     there is a node objects/traces store), per SPEC law 38's volatility
#     exclusion. traces/ records only (cell-id, HASH) pairs, never the raw
#     value; the reading node here returns a fixed string, never the
#     payload itself, so objects/ has no legitimate way to contain it
#     either. (blobs/ is deliberately EXCLUDED from this check: the
#     observe-fn reads the payload via `$file`, which
#     content-addresses it into blobs/ exactly as any fs read would — every
#     file read is content-addressed on the way in, so this is orthogonal
#     to and unaffected by the probe mechanism; only `secret:`-covered
#     reads exclude blobs/, tests/044.)
# =====================================================================
PAYLOAD="PROBE-PAYLOAD-9f3d2a1c"
rm -rf "$TMP/.pp"
printf '%s\n' "$PAYLOAD" > "$TMP/payload.txt"
cat > "$TMP/prog-payload.pp" <<EOF
register-probe!("secretish",
fn() { string-trim(\$file("$TMP/payload.txt")) }, cap-restrict(current-capabilities(), "$TMP/payload.txt", :ro))

log!(force(node {
  \$probe("secretish")
  "checked"
}))
EOF
"$PP" --grant "fs:$TMP:ro" "$TMP/prog-payload.pp" > "$TMP/out" 2>&1
if grep -rq "$PAYLOAD" "$TMP/.pp/store/objects" "$TMP/.pp/store/traces" 2>/dev/null; then
  echo "FAIL probe-value-never-in-store: payload found under objects/traces"
  fail=1
else
  echo "ok   probe-value-never-in-store"
fi

# =====================================================================
# (3) unread probe never fires — a registered-but-never-`$probe(...)`-read
#     probe's observe-fn (a side-effecting `log` marker, capability-free)
#     must never run.
# =====================================================================
rm -rf "$TMP/.pp"
cat > "$TMP/prog-unread.pp" <<EOF
register-probe!("counter", fn() { string->number(string-trim(\$file("$COUNTER"))) }, cap-restrict(current-capabilities(), "$COUNTER", :ro))
register-probe!("unused", fn() { log!("PROBE-FIRED"); 0 }, cap-none())
log!(force(node { \$probe("counter") }))
EOF
printf '1\n' > "$COUNTER"
"$PP" --grant "fs:$TMP:ro" "$TMP/prog-unread.pp" > "$TMP/out" 2>&1
if grep -q "PROBE-FIRED" "$TMP/out"; then
  echo "FAIL unread-probe-never-fires: unused probe's observe-fn ran"; fail=1
else
  echo "ok   unread-probe-never-fires"
fi

# =====================================================================
# (4) unregistered probe errors, naming it
# =====================================================================
cat > "$TMP/prog-unreg.pp" <<'EOF'
print($probe("no-such-probe"))
EOF
rm -rf "$TMP/.pp"
"$PP" "$TMP/prog-unreg.pp" > "$TMP/out" 2>&1
assert "unregistered-probe-errors" '\$probe: unregistered probe: no-such-probe' present
# =====================================================================
# (5) register-probe! is script-tier only (trace_stack guard)
# =====================================================================
cat > "$TMP/prog-in-node.pp" <<EOF
force(node { register-probe!("x", fn() { 1 }, cap-none()) })
EOF
rm -rf "$TMP/.pp"
"$PP" "$TMP/prog-in-node.pp" > "$TMP/out" 2>&1
assert "register-probe-in-node-errors" "node bod" present
# =====================================================================
# (6) --watch: the SAME probe cell change, detected live by one
#     long-running `pp --watch` process on a timer, with no special-cased
#     wiring — a probe read is an ordinary cell observation, so the
#     existing generic watch-loop polling (session observations ->
#     Observation.observe) already covers `probe:` cells for free.
# =====================================================================
rm -rf "$TMP/.pp"
printf '1\n' > "$COUNTER"
timeout 12 "$PP" --watch --watch-interval 0.3 --grant "fs:$TMP:ro" "$TMP/prog.pp" \
  > "$TMP/watch.out" 2>&1 &
WATCH_PID=$!
sleep 1.0
printf '2\n' > "$COUNTER"
sleep 2.0
kill "$WATCH_PID" >/dev/null 2>&1 || true
wait "$WATCH_PID" 2>/dev/null || true

assert "watch-cold-computes"       "COMPUTE"                    present "$TMP/watch.out"
assert "watch-cold-value-1"        "\\[info\\] 1$"               present "$TMP/watch.out"
assert "watch-detects-cell-change" "cell\\(s\\) changed"         present "$TMP/watch.out"
assert "watch-recomputes-value-2"  "\\[info\\] 2$"               present "$TMP/watch.out"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PROBES (M4) TEST PASSED ==="; fi
exit $fail
