#!/usr/bin/env bash
# tests/071 — property tests over randomly generated ASTs and values, proving
# three things always hold.
#
# `lisp/app/main.lisp` owns the deterministic generators for kernel values,
# patterns, and expressions. The property command keeps constructor coverage
# explicit, so adding a form requires adding its generator and classification
# rather than silently shrinking the sampled domain.
#
#   (i)   INJECTIVITY  distinct ASTs => distinct content hashes
#         (`hash-value`, `hash-pattern`, and `hash-expr`, including the node
#         cache key, SPEC law 20).
#         A collision is a wrong-cache-serve bug — the same failure mode
#         closed for observation encodings by tests/070-hash-injective-nearmiss.sh.
#         Also checks a pinned near-miss corpus.
#   (ii)  QUOTE RT     quoting and reifying a value is total and idempotent
#         (the macro reflect/reify projection reaches a fixpoint) — pp's
#         metaprogramming is served by total quote/quasiquote plus defmacro,
#         never fexprs.
#   (iii) PRINT RT     read then print is hash-preserving on both surfaces for
#         the reader-image subset (documented per-form in the surface table).
#
# The runtime gate runs the suite across several seeds and asserts all
# properties hold. Constructor coverage is reported in the command summary.
#
# Two real defects were caught writing this and are pinned here by construction
# (they'd re-fail the property if reverted):
#   - an island with no pin was distinguished from one pinned to the empty
#     string (injectivity);
#   - tagged patterns and spread-only list patterns printed in forms the
#     corresponding reader could not parse.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# Several seeds, a solid sample each. Deterministic given the seed.
for seed in 1 2 3 7 42; do
  out=$("$PP" --check-kernel-props --seed "$seed" --count 3000 2>&1)
  rc=$?
  if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q "^kernel-props: OK"; then
    ok "seed-$seed"
  else
    bad "seed-$seed" "kernel property failure (rc=$rc):" \
        "$(printf '%s\n' "$out" | sed 's/^/       /')"
  fi
done

# The properties must actually exercise every constructor and not skip the
# whole printer round-trip. Assert the coverage line reports full form/kind
# coverage and a non-trivial number of print-rt checks.
summary=$("$PP" --check-kernel-props --seed 1 --count 3000 2>&1 | grep "^kernel-props: seed")
if printf '%s\n' "$summary" | grep -q "forms=28/28"; then
  ok "expr-form-coverage"
else
  bad "expr-form-coverage" "expected forms=28/28 in: $summary"
fi
if printf '%s\n' "$summary" | grep -qE "print-rt: [1-9][0-9]{3,} checked"; then
  ok "print-rt-non-vacuous"
else
  bad "print-rt-non-vacuous" "print-rt checked count too low in: $summary"
fi

if [ $fail -eq 0 ]; then echo "=== KERNEL PROPS (A″2) TEST PASSED ==="; fi
exit $fail
