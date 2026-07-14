#!/usr/bin/env bash
# tests/068 — A′3: `needs` is value-open (both backends).
#
# `needs` accepts ANY expression evaluating to a capability. The dotted
# descriptors (`fs.read`/`fs.write`/`fs.rw`) are table-driven sugar
# (Surface_tables.grant_sugar); everything else passes through to the node's
# with-caps wrapper unchanged — "the reader adds nothing" (SPEC L35). So a
# NAMED grant (`let g = cap-restrict(...)`) and a COMPOSED grant
# (`cap-compose(...)`) are first-class `needs` items, identical to the sugar.
# The capability *kind* set stays closed (DESIGN §1 principle 7); the
# vocabulary of named grants is open at the value level.
#
# This pins: (a) sugar, named, and composed grants all run and agree across
# backends; (b) a named grant genuinely NARROWS — the ⊆ gate (LAW 22b), not
# the reader, does the enforcing — denying a read outside its scope identically
# on both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

T=$(mktemp -d)
echo "hello-grant" > "$T/data.txt"
mkdir -p "$T/other"
GRANT=(--grant "fs:$T:ro")

# --- positive: three needs spellings, all read the same granted file --------
cat > "$T/prog.pp" <<EOF
def rd() { string-trim(slurp("$T/data.txt")) }

# (a) descriptor sugar
node via-sugar() needs fs.read("$T") { rd() }

# (b) a NAMED grant — an ordinary let binding used as the needs item
let ro-grant = cap-restrict(current-capabilities(), "$T", :ro)
node via-named() needs ro-grant { rd() }

# (c) a COMPOSED grant, also named
let combined = cap-compose(cap-restrict(current-capabilities(), "$T", :ro), cap-none())
node via-composed() needs combined { rd() }

print(via-sugar())
print(via-named())
print(via-composed())
EOF
expected=$'"hello-grant"\n"hello-grant"\n"hello-grant"'
got_tw=$("$PP"            "${GRANT[@]}" "$T/prog.pp" 2>&1)
got_bc=$("$PP" --bytecode "${GRANT[@]}" "$T/prog.pp" 2>&1)
if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
  ok "sugar-named-composed-grants-agree"
else
  bad "sugar-named-composed-grants-agree" \
      "expected: $(printf '%q' "$expected")" \
      "tw:       $(printf '%q' "$got_tw")" \
      "bc:       $(printf '%q' "$got_bc")"
fi

# --- negative: a named grant NARROWS; reading outside its scope is denied,
#     identically on both backends (the value, not the reader, restricts) -----
cat > "$T/neg.pp" <<EOF
let narrow = cap-restrict(current-capabilities(), "$T/other", :ro)
node blocked() needs narrow { slurp("$T/data.txt") }
print(blocked())
EOF
neg_tw=$("$PP"            "${GRANT[@]}" "$T/neg.pp" 2>&1)
neg_bc=$("$PP" --bytecode "${GRANT[@]}" "$T/neg.pp" 2>&1)
if [ "$neg_tw" = "$neg_bc" ] \
   && echo "$neg_tw" | grep -q "permission denied" \
   && echo "$neg_tw" | grep -q "data.txt"; then
  ok "named-grant-narrows-denies-identically"
else
  bad "named-grant-narrows-denies-identically" \
      "tw: $(printf '%q' "$neg_tw")" \
      "bc: $(printf '%q' "$neg_bc")"
fi

exit $fail
