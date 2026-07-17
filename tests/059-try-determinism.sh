#!/usr/bin/env bash
# tests/059 — deterministic `try` lowering.
#
# `try {}` lowers to a nested if-chain over fresh temp names (`__try_N`).
# Those names land in the AST and therefore in the content hash (SPEC law
# 20). If the counter that mints them is process-global and never reset, a
# form's hash depends on how many `try` blocks were parsed *before* it — so
# the same source hashes differently depending on parse order, and pp can
# serve a wrong cached result. This test pins the invariant: a form's hash
# is a pure function of the form (and its location), independent of parse
# history.
#
# Mechanism: `--compare-hash f1 f2` reads f1 fully, then f2 fully, in one
# process, and diffs their per-top-level-form hashes. With a global counter,
# reading f1 bumps it, so identical f2 forms hash differently — a red build.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# (a) Two byte-identical files, each a single `try`-using form. Reading the
#     first must not perturb the hash of the second: identical text ⇒
#     identical per-form hash regardless of read order in the process.
cat > "$TMP/one.pp" <<'EOF'
def compute(x, y) {
  try {
    a <- divide(x, y)
    b <- divide(a, 2)
    [:ok, a + b]
  }
}
EOF
cp "$TMP/one.pp" "$TMP/one-copy.pp"
if "$PP" --compare-hash "$TMP/one.pp" "$TMP/one-copy.pp" >/dev/null 2>&1; then
  ok "identical-single-try-form"
else
  bad "identical-single-try-form" \
      "byte-identical files produced divergent LAW-20 hashes"
fi

# (b) A file with two structurally-identical `try` forms at different lines,
#     compared to a byte-identical copy. Each top-level form must number its
#     temps from scratch, so both copies agree form-for-form. (The two forms
#     within a file still differ from each other via their ELocated line —
#     that is expected; this only pins cross-parse stability.)
cat > "$TMP/two.pp" <<'EOF'
def f(x, y) {
  try {
    a <- divide(x, y)
    [:ok, a]
  }
}
def g(x, y) {
  try {
    a <- divide(x, y)
    [:ok, a]
  }
}
EOF
cp "$TMP/two.pp" "$TMP/two-copy.pp"
if "$PP" --compare-hash "$TMP/two.pp" "$TMP/two-copy.pp" >/dev/null 2>&1; then
  ok "two-try-forms-per-form-reset"
else
  bad "two-try-forms-per-form-reset" \
      "per-form temp numbering not reset — hashes depend on parse history"
fi

# (c) The lowering must still be correct after the reset: a multi-bind try
#     (with several temps in one form) must produce the correct output.
cat > "$TMP/run.pp" <<'EOF'
def divide(x, y) {
  if =(y, 0) { [:err, "div by zero"] } else { [:ok, x / y] }
}
def compute(x, y) {
  try {
    a <- divide(x, y)
    b <- divide(a, 2)
    [:ok, a + b]
  }
}
print(compute(20, 2))
print(compute(20, 0))
EOF
expected=$'(:ok 15)\n(:err "div by zero")'
got=$("$PP" "$TMP/run.pp" 2>&1)
if [ "$got" = "$expected" ]; then
  ok "try-lowering-deterministic"
else
  bad "try-lowering-deterministic" \
      "got: $(printf '%q' "$got")"
fi

exit $fail
