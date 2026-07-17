#!/usr/bin/env bash
# Introspection and cache-control flags: `pp why` (capability-filtered),
# --no-cache, --check.
#
#   why       — per node force, report to stderr why it hit or missed:
#               first build (no trace), stale (which cell changed), hit
#               (which trace verified), or unauthorized. The report is
#               CAPABILITY-FILTERED (SPEC law 23c): a cell the caller has no
#               authority over is redacted, so `why` cannot be used to probe
#               what a broader caller read.
#   --no-cache — skip cache READS (every node recomputes) but still write
#               fresh results/traces.
#   --check   — determinism audit (SPEC law 38): after computing a node, run its
#               body a second time and compare result hashes; a divergence
#               flags the node as volatile and the run exits nonzero.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
WORK="$TMP/work"; PRIV="$TMP/priv"
mkdir -p "$WORK" "$PRIV"
fail=0

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

printf 'V1\n' > "$WORK/data.txt"
cat > "$TMP/p.pp" <<EOF
perform log(force(node {
  perform log("COMPUTE")
  slurp("$WORK/data.txt")
}))
EOF

# --- (a) why: first build, hit, stale ---
rm -rf "$TMP/.pp"
run why --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "why-first-build"   "\[why\].*miss"       present
run why --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "why-hit"           "\[why\].*hit"        present
assert "why-hit-no-run"    "COMPUTE"             absent
printf 'V2\n' > "$WORK/data.txt"
run why --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "why-stale"         "\[why\].*stale"      present
assert "why-stale-names-cell" "data\.txt"        present

# --- (b) why is capability-filtered: an unauthorized cell is redacted ---
printf 'SECRETPATHCONTENT\n' > "$PRIV/secret-name.txt"
cat > "$TMP/q.pp" <<EOF
perform log(force(node {
  perform log("COMPUTE")
  slurp("$PRIV/secret-name.txt")
}))
EOF
rm -rf "$TMP/.pp"
run --grant "fs:$TMP:ro" "$TMP/q.pp"                  # broad run populates
run why --grant "fs:$WORK:ro" "$TMP/q.pp"             # narrow caller asks why
assert "why-unauthorized"       "\[why\].*unauthorized" present
assert "why-redacts-cell"       "redacted"              present
assert "why-no-secret-leak"     "\[why\].*secret-name"  absent

# --- (c) --no-cache: recompute despite a valid cache, but still re-store ---
rm -rf "$TMP/.pp"
printf 'V1\n' > "$WORK/data.txt"
run --grant "fs:$WORK:ro" "$TMP/p.pp"
run --no-cache --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "nocache-recomputes" "COMPUTE" present
run --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "nocache-still-stored" "COMPUTE" absent   # the no-cache run refreshed the store

# --- (d) --check: a deterministic node passes, a volatile one is flagged ---
rm -rf "$TMP/.pp"
run --check --grant "fs:$WORK:ro" "$TMP/p.pp"
assert "check-deterministic" "volatile" absent
if [ -s "$TMP/out" ] && ! grep -q "Fatal" "$TMP/out"; then echo "ok   check-det-exit"
else echo "FAIL check-det-exit"; cat "$TMP/out"; fail=1; fi
cat > "$TMP/vol.pp" <<'EOF'
perform log(force(node {
  hash-map-get(perform run("head", "-c", "4", "/dev/urandom"), "out")
}))
EOF
rm -rf "$TMP/.pp"
if run --check --grant process "$TMP/vol.pp"; then
  echo "FAIL check-volatile-exit: expected nonzero exit"; cat "$TMP/out"; fail=1
else echo "ok   check-volatile-exit"; fi
assert "check-volatile-flagged" "volatile" present

rm -rf "$TMP"

if [ "$fail" -eq 0 ]; then echo "=== WHY / NO-CACHE / CHECK TEST PASSED ==="; fi
exit $fail
