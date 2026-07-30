#!/usr/bin/env bash
# tests/068 — `needs` is value-open.
#
# `needs` accepts ANY expression evaluating to a capability. The dotted
# descriptors (`fs.read`/`fs.write`/`fs.rw`) are table-driven sugar
# (Surface_tables.grant_sugar); everything else passes through to the node's
# with-caps wrapper unchanged — "the reader adds nothing". So a NAMED grant
# (`let g = cap-restrict(...)`) and a COMPOSED grant (`cap-compose(...)`) are
# first-class `needs` items, identical to the sugar. The capability *kind*
# set stays closed; the vocabulary of named grants is open at the value
# level.
#
# This pins: (a) sugar, named, and composed grants all run and produce the
# same result; (b) a named grant genuinely NARROWS — the subset gate (SPEC law
# 22b), not the reader, does the enforcing.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
T=$(mktemp -d)
echo "hello-grant" > "$T/data.txt"
mkdir -p "$T/other"
GRANT=(--grant "fs:$T:ro")

# --- positive: three needs spellings, all read the same granted file --------
cat > "$T/prog.pp" <<EOF
def rd() { string-trim(\$file("$T/data.txt")) }

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
got=$("$PP" "${GRANT[@]}" "$T/prog.pp" 2>&1)
if [ "$got" = "$expected" ]; then
  ok "sugar-named-composed-grants-agree"
else
  bad "sugar-named-composed-grants-agree" \
      "expected: $(printf '%q' "$expected")" \
      "got:      $(printf '%q' "$got")"
fi

# --- negative: a named grant NARROWS; reading outside its scope is denied
#     (the value, not the reader, restricts) -----
cat > "$T/neg.pp" <<EOF
let narrow = cap-restrict(current-capabilities(), "$T/other", :ro)
node blocked() needs narrow { \$file("$T/data.txt") }
print(blocked())
EOF
neg=$("$PP" "${GRANT[@]}" "$T/neg.pp" 2>&1)
if echo "$neg" | grep -qE "permission denied|not granted" \
   && echo "$neg" | grep -q "data.txt"; then
  ok "named-grant-narrows-denies"
else
  bad "named-grant-narrows-denies" \
      "got: $(printf '%q' "$neg")"
fi

exit $fail
