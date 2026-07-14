#!/usr/bin/env bash
# pins: LAW-23
# Regression: a cache hit is gated on the caller's authority over the trace's
# transitive read closure (LAW 23b) — the PUB = f(SECRET) laundering defense.
#
# A node keyed by LAW 20 excludes capabilities from its identity, so a
# broad-capability run and a narrow-capability run compute the SAME key. Without
# a hit-time check, the narrow caller would get a hit and learn the broad read's
# result. The store therefore serves a hit only if the caller is authorized to
# read every cell in the stored trace's closure (which, thanks to read
# propagation, includes cells read by nested child nodes).
#
# Also pins that a capability denial is NOT memoized as a failing trace (LAW 15:
# authority is not identity/validity), so a later authorized run still hits.
#
# Tree-walker only, isolated HOME. "SECRET" leaking to stdout is the failure.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
mkdir -p "$TMP/secret" "$TMP/other"
printf 'SECRETDATA\n' > "$TMP/secret/data.txt"
printf 'ok\n' > "$TMP/other/x.txt"
fail=0

# out contains SECRETDATA?  denied?  (permission-denied error)
assert() {  # NAME  secret=leaked|safe  access=ok|denied
  local name="$1" smode="$2" amode="$3"
  local leaked denied
  if grep -q "SECRETDATA" "$TMP/o"; then leaked=leaked; else leaked=safe; fi
  if grep -q "permission denied" "$TMP/o"; then denied=denied; else denied=ok; fi
  if [ "$leaked" = "$smode" ] && [ "$denied" = "$amode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: secret=$leaked (want $smode), access=$denied (want $amode)"
    cat "$TMP/o"; fail=1
  fi
}

# --- direct: node reads the secret ---
cat > "$TMP/direct.pp" <<EOF
perform log(force(node { slurp("$TMP/secret/data.txt") }))
EOF
rm -rf "$TMP/.pp"
"$PP" --grant "fs:$TMP:ro"        "$TMP/direct.pp" > "$TMP/o" 2>&1; assert "broad-run-caches"     leaked ok
"$PP" --grant "fs:$TMP/other:ro"  "$TMP/direct.pp" > "$TMP/o" 2>&1; assert "narrow-run-denied"    safe   denied
"$PP" --grant "fs:$TMP:ro"        "$TMP/direct.pp" > "$TMP/o" 2>&1; assert "broad-hit-restored"   leaked ok

# --- transitive: outer node forces an inner node that reads the secret ---
cat > "$TMP/nest.pp" <<EOF
perform log(force(node {
  perform log("OUTER")
  force(node { slurp("$TMP/secret/data.txt") })
}))
EOF
rm -rf "$TMP/.pp"
"$PP" --grant "fs:$TMP:ro"       "$TMP/nest.pp" > "$TMP/o" 2>&1; assert "nest-broad-caches"   leaked ok
"$PP" --grant "fs:$TMP/other:ro" "$TMP/nest.pp" > "$TMP/o" 2>&1; assert "nest-narrow-denied"  safe   denied

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== NODE-HIT CAPABILITY TEST PASSED ==="; fi
exit $fail
