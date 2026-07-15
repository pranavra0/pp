#!/usr/bin/env bash
# tests/064 — `pp lint` sweep for vector-get/vector-length on a bracket
# literal.
#
# The bracket literal `[…]` now reads as `(list …)`, not `(vector …)`. So
# `vector-get([…], i)` / `vector-length([…])` — idioms from the vector era —
# now apply a vector accessor to a list and fail at runtime. `pp lint` catches
# this statically: it warns on vector-get/vector-length whose first argument is
# a bracket literal, and must NOT warn when the argument is a real `vector(…)`.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# vector accessors on bracket literals (should warn) plus the correct vector(…)
# form (should NOT warn).
cat > "$TMP/sweep.pp" <<'EOF'
let a = vector-get([10, 20, 30], 1)
let b = vector-length([1, 2])
let c = vector-get(vector(7, 8, 9), 0)
let d = vector-length(vector(1))
print(c)
print(d)
EOF
out=$("$PP" lint "$TMP/sweep.pp" 2>&1 || true)

n_get=$(echo "$out" | grep -c 'vector-get applied to a bracket literal')
n_len=$(echo "$out" | grep -c 'vector-length applied to a bracket literal')
n_total=$(echo "$out" | grep -c 'bracket literal')

if [ "$n_get" = "1" ] && [ "$n_len" = "1" ] && [ "$n_total" = "2" ]; then
  ok "flags-vector-accessors-on-bracket-literal-only"
else
  bad "flags-vector-accessors-on-bracket-literal-only" \
      "expected exactly 1 get + 1 len warning, 2 total" \
      "got: $(printf '%q' "$out")"
fi

# The vector(…) lines must be clean — assert neither is mentioned.
if echo "$out" | grep -q 'vector(7' ; then
  bad "no-false-positive-on-real-vector" "warned on a real vector(…)"
else
  ok "no-false-positive-on-real-vector"
fi

# A file with no such misuse lints clean (no bracket-literal warnings).
cat > "$TMP/clean.pp" <<'EOF'
let xs = [1, 2, 3]
let n = length(xs)
print(n)
EOF
out2=$("$PP" lint "$TMP/clean.pp" 2>&1 || true)
if echo "$out2" | grep -q 'bracket literal'; then
  bad "clean-file-no-bracket-warning" "got: $(printf '%q' "$out2")"
else
  ok "clean-file-no-bracket-warning"
fi

exit $fail
