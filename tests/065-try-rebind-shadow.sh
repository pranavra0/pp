#!/usr/bin/env bash
# tests/065 — `try {}` <- bindings are sequential, and rebinding shadows
# (the documented SPEC law 4 exception).
#
# SPEC law 4 makes ordinary blocks letrec*: defining a name twice in one
# block is a read error ("duplicate definition in block"). A `try {}` block
# is the one exception — it lowers to nested `let`s, so its `<-` bindings
# execute top to bottom and rebinding the SAME name simply shadows the
# earlier binding for the statements that follow. This pins that: a try
# block that rebinds `x` twice must (a) parse (not raise a
# duplicate-definition read error) and (b) evaluate so later uses see the
# shadowing value.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_both() {
  # $1: name, $2: file, $3: expected output
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" \
        "expected: $(printf '%q' "$expected")" \
        "got:      $(printf '%q' "$got")"
  fi
}

# (a) Rebind `x` twice. Each `<-` rhs sees the PREVIOUS binding of x; the final
#     `x` is the last shadowing value. 1 -> (+10) 11 -> (*2) 22.
cat > "$TMP/rebind.pp" <<'EOF'
let r = try {
  x <- [:ok, 1]
  x <- [:ok, x + 10]
  x <- [:ok, x * 2]
  x
}
print(r)
EOF
run_both "try-rebind-x-twice-sequential" "$TMP/rebind.pp" "22"

# (b) A rebinding whose rhs short-circuits on :err must propagate — proving the
#     binds are sequential lets, not a mutually-visible block (a letrec* block
#     could not even express "the second bind depends on the first").
cat > "$TMP/rebind-err.pp" <<'EOF'
let r = try {
  x <- [:ok, 5]
  x <- [:err, "stopped"]
  x <- [:ok, x + 100]
  x
}
print(r)
EOF
run_both "try-rebind-short-circuits-on-err" "$TMP/rebind-err.pp" '(:err "stopped")'

# (c) The same double-binding, at ORDINARY (letrec*) block level, IS a
#     duplicate-definition read error — the contrast that makes try the
#     exception.
cat > "$TMP/dup.pp" <<'EOF'
let bad = do {
  let x = 1
  let x = 2
  x
}
print(bad)
EOF
got=$("$PP" "$TMP/dup.pp" 2>&1 || true)
if echo "$got" | grep -qi 'duplicate'; then
  ok "ordinary-block-double-def-still-rejected"
else
  bad "ordinary-block-double-def-still-rejected" \
      "got: $(printf '%q' "$got")"
fi

exit $fail
