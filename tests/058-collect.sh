#!/usr/bin/env bash
# tests/058 — Differential test for `collect` error partitioning.
# B2: `collect` is now a plain FUNCTION used in pipelines (the renamed
# `collect-results` primitive); the `collect { }` reader block form is removed.
# `collect(items)` partitions a list of [:ok, v]/[:err, e] — [:ok, values] if
# all succeeded, [:err, errors] if any failed. The validation counterpart to
# `try`'s short-circuit.
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

# All ok — as a direct call.
cat > "$TMP/all-ok.pp" <<'EOF'
let items = [[:ok, 1], [:ok, "hi"], [:ok, [:nested, :val]]]
print(collect(items))
EOF
run_both "collect-all-ok" "$TMP/all-ok.pp" '(:ok (1 "hi" (:nested :val)))'

# One error short-circuits into the [:err, errors] arm — via a pipeline.
cat > "$TMP/one-err.pp" <<'EOF'
print([[:ok, 1], [:err, "boom"], [:ok, 2]] |> collect)
EOF
run_both "collect-one-err-pipeline" "$TMP/one-err.pp" '(:err ("boom"))'

# All errors are accumulated (validation, not short-circuit).
cat > "$TMP/all-err.pp" <<'EOF'
print([[:err, "first"], [:err, "second"], [:err, "third"]] |> collect)
EOF
run_both "collect-all-err" "$TMP/all-err.pp" '(:err ("first" "second" "third"))'

# Empty list.
cat > "$TMP/empty.pp" <<'EOF'
print(collect([]))
EOF
run_both "collect-empty" "$TMP/empty.pp" '(:ok nil)'

# The `collect { }` block form is gone: `collect` is an ordinary identifier.
cat > "$TMP/ident.pp" <<'EOF'
let collect = 42
print(collect)
EOF
run_both "collect-is-ordinary-identifier" "$TMP/ident.pp" '42'

rm -rf "$TMP"
exit $fail
