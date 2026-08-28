#!/usr/bin/env bash
# tests/075 — property tests proving capabilities can only be narrowed, never
# widened or invented, and can never leak across a node boundary.
# pins: LAW-22b LAW-23 LAW-39
#
# `lisp/app/main.lisp` generates capability values through the kernel's
# capability constructors, and `--check-kernel-props` runs four algebra
# properties over the generated values. Constructor coverage is reported in
# the command summary, so new capability forms cannot disappear untested:
#
#   (a) cap-restrict-narrows    a `cap-restrict` grants only what its
#                               underlying capability already granted.
#   (b) cap-compose-union       a `cap-compose` grants EXACTLY the union of its
#                               parts (invents no authority; loses none).
#   (c) cap-subseteq-sound      the `with-caps` subset gate (SPEC law 22b)
#                               never approves a request that grants authority
#                               the ambient scope lacks.
#   (d) node-boundary ban       durable-value validation (SPEC law 39, the ban
#                               on capabilities crossing a node boundary)
#                               catches a capability or sealed value buried at
#                               any depth, and does not false-positive on a
#                               capability-free value.
#
# The generated values exercise all four properties. This test is the runtime
# gate — it runs the suite across several seeds and asserts full capability
# kind coverage and a non-trivial check count.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
for seed in 1 2 3 7 42; do
  out=$("$PP" --check-kernel-props --seed "$seed" --count 3000 2>&1)
  rc=$?
  if [ $rc -eq 0 ] && printf '%s\n' "$out" | grep -q "^kernel-props: OK"; then
    ok "seed-$seed"
  else
    bad "seed-$seed" "kernel/caps property failure (rc=$rc):" \
        "$(printf '%s\n' "$out" | sed 's/^/       /')"
  fi
done

# The caps property must exercise every capability kind and run a non-trivial
# number of checks (guards against a vacuous run that silently covered nothing).
summary=$("$PP" --check-kernel-props --seed 1 --count 3000 2>&1 | grep "^kernel-props: seed")
if printf '%s\n' "$summary" | grep -q "cap-kinds=7/7"; then
  ok "cap-kind-coverage"
else
  bad "cap-kind-coverage" "expected cap-kinds=7/7 in: $summary"
fi
if printf '%s\n' "$summary" | grep -qE "cap-checks: [1-9][0-9]{3,}"; then
  ok "cap-checks-non-vacuous"
else
  bad "cap-checks-non-vacuous" "cap-checks count too low in: $summary"
fi

if [ $fail -eq 0 ]; then echo "=== CAP PROPS (A″6) TEST PASSED ==="; fi
exit $fail
