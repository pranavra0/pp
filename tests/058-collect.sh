#!/usr/bin/env bash
# tests/058 — Differential test for collect { } error partitioning (Phase 1b.4).
# Tests the `collect-results` builtin via the `collect { }` reader sugar.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

run_both() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP" "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" != "$expected" ]; then
    bad "$name-tw" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got_tw")"
  elif [ "$got_bc" != "$expected" ]; then
    bad "$name-bc" "expected: $(printf '%q' "$expected")" "got:      $(printf '%q' "$got_bc")"
  else
    ok "$name"
  fi
}

cat > "$TMP/all-ok.pp" <<'EOF'
let a = [:ok, 1]
let b = [:ok, "hi"]
let c = [:ok, [:nested, :val]]
let result = collect { a; b; c }
print(result)
EOF
run_both "collect-all-ok" "$TMP/all-ok.pp" '(:ok (1 "hi" (:nested :val)))'

cat > "$TMP/one-err.pp" <<'EOF'
let a = [:ok, 1]
let b = [:err, "boom"]
let c = [:ok, 2]
let result = collect { a; b; c }
print(result)
EOF
run_both "collect-one-err" "$TMP/one-err.pp" '(:err ("boom"))'

cat > "$TMP/all-err.pp" <<'EOF'
let a = [:err, "first"]
let b = [:err, "second"]
let c = [:err, "third"]
let result = collect { a; b; c }
print(result)
EOF
run_both "collect-all-err" "$TMP/all-err.pp" '(:err ("first" "second" "third"))'

cat > "$TMP/empty.pp" <<'EOF'
let result = collect {  }
print(result)
EOF
run_both "collect-empty" "$TMP/empty.pp" '(:ok nil)'

rm -rf "$TMP"
exit $fail
