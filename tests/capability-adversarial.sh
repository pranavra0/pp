#!/usr/bin/env bash
# Adversarial capability suite — Phase 0 exit (3).
# Runs both backends and compares their verdicts.
set -euo pipefail
PP=${PP:-./pp}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run_case() {
  local name="$1"; shift
  local expected="$1"; shift
  local tw_out="$TMP/tw-$name.out"
  local bc_out="$TMP/bc-$name.out"
  "$PP" "$@" > "$tw_out" 2>&1 || true
  "$PP" --bytecode "$@" > "$bc_out" 2>&1 || true
  local tw_ok=false
  local bc_ok=false
  grep -qE "$expected" "$tw_out" && tw_ok=true
  grep -qE "$expected" "$bc_out" && bc_ok=true
  if $tw_ok && $bc_ok; then
    echo "ok $name"
  else
    echo "FAIL $name: expected '$expected' in both backends"
    echo "--- tree-walker ---"; cat "$tw_out"
    echo "--- bytecode ---"; cat "$bc_out"
    return 1
  fi
}

# Positive: --grant gives read access to /tmp but not /tmpevil.
echo "pp-cap-allowed" > "$TMP/allowed.txt"
cp "$TMP/allowed.txt" /tmp/pp-cap-test-file 2>/dev/null || true

cat > "$TMP/read-allowed.pp" <<'EOF'
(print (slurp "/tmp/pp-cap-test-file"))
EOF
run_case read-allowed "pp-cap-allowed" "$TMP/read-allowed.pp" --grant fs:/tmp:ro

# Negative: path-component scope — /tmp must NOT grant /tmpevil.
cat > "$TMP/read-denied.pp" <<'EOF'
(print (slurp "/tmpevil/secret"))
EOF
run_case path-component-denied "slurp: permission denied" "$TMP/read-denied.pp" --grant fs:/tmp:ro

# Negative: capability constructors removed from user code.
run_case constructor-filesystem "unbound.*filesystem" -e '(print (filesystem "/" :rw))'
run_case constructor-network     "unbound.*network"     -e '(print (network :any))'
run_case constructor-process     "unbound.*process"     -e '(print (process))'

# Negative: read-file without any grant.
run_case read-no-grant "capability error: no read access" -e '(print (perform read-file "/etc/hostname"))'

# Positive: cap-restrict and cap-compose work on an already-granted cap.
cat > "$TMP/cap-ops.pp" <<'EOF'
(let [sub (cap-restrict (cap-compose (cap-none) (cap-none)) "x")]
  (print "restricted:" sub))
EOF
run_case cap-ops "restricted:" "$TMP/cap-ops.pp"

echo "=== ALL ADVERSARIAL TESTS PASSED ==="
