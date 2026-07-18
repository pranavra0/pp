#!/usr/bin/env bash
# Two observation encodings that used to hash identically now hash
# differently, so each recomputes instead of wrongly serving the other's
# cached result.
#
# hash_concat frames every part as `<len>:<bytes>` (src/core_model.ml), so two
# distinct part LISTS can never share a pre-hash string just because a part
# contains ':' or matches an absent-marker. Two observation encodings that
# collided under the old `String.concat ":"` join are the surface-reachable
# witnesses; each must now RECOMPUTE across the two world-states rather than
# serve the other's cached result, and each must still re-HIT on return to the
# original state (the framing is deterministic, not merely different):
#
#   (a) env-absent vs value "absent": a variable whose value is literally
#       "absent" once hashed identically to an unset variable
#       (`hash_string ("env:"^s)` == `hash_string "env:absent"`).
#   (b) argv ["a","b"] vs ["a:b"]: the ':' join made "argv:a:b" ambiguous.
#
# COMPUTE in output = the node body ran (miss); a hit does not replay it
# (SPEC law 17). Runs under an isolated HOME.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME want(miss|hit)
  local name="$1" want="$2"
  if grep -qE "COMPUTE" "$TMP/out"; then got=miss; else got=hit; fi
  if [ "$got" = "$want" ]; then echo "ok   $name"
  else echo "FAIL $name: expected $want, got $got"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

# ---- (a) env observation: absent vs the literal value "absent" ----
cat > "$TMP/env.pp" <<'EOF'
perform log(force(node {
  perform log("COMPUTE")
  env-get("PPTEST_A1")
}))
EOF

env_case() {
  rm -rf "$TMP/.pp"
  unset PPTEST_A1
  "$PP" "$TMP/env.pp" > "$TMP/out" 2>&1
  assert "env-unset-run1-miss" miss
  PPTEST_A1=absent "$PP" "$TMP/env.pp" > "$TMP/out" 2>&1
  assert "env-value-absent-recomputes" miss
  unset PPTEST_A1
  "$PP" "$TMP/env.pp" > "$TMP/out" 2>&1
  assert "env-unset-again-hits" hit
}
env_case

# ---- (b) argv observation: ["a","b"] vs ["a:b"] ----
cat > "$TMP/argv.pp" <<'EOF'
perform log(force(node {
  perform log("COMPUTE")
  argv()
}))
EOF

argv_case() {
  rm -rf "$TMP/.pp"
  "$PP" "$TMP/argv.pp" -- a b > "$TMP/out" 2>&1
  assert "argv-ab-run1-miss" miss
  "$PP" "$TMP/argv.pp" -- a:b > "$TMP/out" 2>&1
  assert "argv-a-colon-b-recomputes" miss
  "$PP" "$TMP/argv.pp" -- a b > "$TMP/out" 2>&1
  assert "argv-ab-again-hits" hit
}
argv_case

if [ "$fail" = 0 ]; then echo "=== 070 HASH-INJECTIVE NEAR-MISS: ALL PASS ==="; fi
exit $fail
