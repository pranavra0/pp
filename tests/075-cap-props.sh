#!/usr/bin/env bash
# tests/075 — A″6: capability-algebra properties.
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
#   (c) cap-subseteq-sound      the with-caps ⊆ gate (cap_subseteq, LAW 22b)
#                               never approves a request that grants authority
#                               the ambient lacks — the "narrow only" gate is
#                               sound against the check_* functions each effect
#                               actually enforces.
#   (d) node-boundary ban       Hasher.contains_authority (LAW 39 / M3 kill-list)
#                               catches a capability OR sealed value buried at
#                               any depth, and does not false-positive on a
#                               capability-free value.
#
# Coverage is derived, not enumerated: a new capability kind extends all four
# properties at once (DESIGN §1 principle 8). This test is the runtime gate — it
# runs the suite across several seeds and asserts the caps properties hold with
# full kind coverage and a non-trivial check count.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

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
