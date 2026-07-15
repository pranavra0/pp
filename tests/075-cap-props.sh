#!/usr/bin/env bash
# tests/075 — property tests proving capabilities can only be narrowed, never
# widened or invented, and can never leak across a node boundary.
# pins: LAW-22b LAW-23 LAW-39
#
# src/kernel_props.ml carries a generator over capability VALUES, exhaustive
# over the capability kind variant (the same compiler ratchet as the AST
# generators — a new CapKind breaks cap_kind's match, then gen_cap_of_tag), and
# four algebra properties run over its whole output via --check-kernel-props:
#
#   (a) cap-restrict-narrows    a raw CapRestrict grants only what its underlying
#                               cap already granted — attenuation never widens.
#   (b) cap-compose-union       a CapCompose grants EXACTLY the union of its
#                               parts (invents no authority; loses none).
#   (c) cap-subseteq-sound      the with-caps ⊆ gate (cap_subseteq, SPEC law 22b)
#                               never approves a request that grants authority
#                               the ambient lacks — the "narrow only" gate is
#                               sound against the check_* functions each effect
#                               actually enforces.
#   (d) node-boundary ban       Hasher.contains_authority (SPEC law 39, the ban
#                               on capabilities crossing a node boundary)
#                               catches a capability OR sealed value buried at
#                               any depth, and does not false-positive on a
#                               capability-free value.
#
# Coverage is derived, not enumerated: a new capability kind extends all four
# properties at once, from the generator's own exhaustiveness match. This test
# is the runtime gate — it runs the suite across several seeds and asserts the
# caps properties hold with full kind coverage and a non-trivial check count.
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
