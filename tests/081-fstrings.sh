#!/usr/bin/env bash
# tests/081 — C1: f-strings. `f"…{expr}…"` (prefix glued to the quote); holes
# take arbitrary expressions and lower through the generic `->string`. Ordinary
# strings never interpolate; `{{`/`}}` are literal braces. f-strings lower to
# `string-append`/`->string` (one-way sugar), so they round-trip through
# `pp fmt` hash-preserved. Every case is checked on BOTH backends; a macro
# template exercises the quasiquote path (parity).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP"            "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
  fi
}

# (a) the canonical case: interpolation of a name and a computed expression.
cat > "$TMP/basic.pp" <<'EOF'
let name = "world"
let x = 41
print(f"Hello, {name}! Value: {x + 1}.")
EOF
run_ok "basic-interpolation" "$TMP/basic.pp" '"Hello, world! Value: 42."'

# (b) no holes → identical to a plain string.
cat > "$TMP/noholes.pp" <<'EOF'
print(f"plain text, no holes")
EOF
run_ok "no-holes" "$TMP/noholes.pp" '"plain text, no holes"'

# (c) empty f-string.
cat > "$TMP/empty.pp" <<'EOF'
print(f"")
EOF
run_ok "empty-fstring" "$TMP/empty.pp" '""'

# (d) a single-hole f-string coerces via ->string (numbers become strings).
cat > "$TMP/single.pp" <<'EOF'
let x = 41
print(f"{x}")
EOF
run_ok "single-hole-coerces" "$TMP/single.pp" '"41"'

# (e) `{{`/`}}` are literal braces.
cat > "$TMP/braces.pp" <<'EOF'
let x = 5
print(f"a set {{ {x} }} literal")
EOF
run_ok "escaped-braces" "$TMP/braces.pp" '"a set { 5 } literal"'

# (f) ordinary strings NEVER interpolate — {x} is three literal characters.
cat > "$TMP/plain.pp" <<'EOF'
let x = 9
print("{x} stays literal")
EOF
run_ok "ordinary-string-no-interp" "$TMP/plain.pp" '"{x} stays literal"'

# (g) a hole may contain a nested string literal (with its own braces/quotes).
cat > "$TMP/nested-str.pp" <<'EOF'
print(f"got: {string-append("a{", "}b")}")
EOF
run_ok "nested-string-in-hole" "$TMP/nested-str.pp" '"got: a{}b"'

# (h) a hole may contain a nested map literal.
cat > "$TMP/nested-map.pp" <<'EOF'
print(f"map {hash-map-get({ :k -> 9 }, :k)}")
EOF
run_ok "nested-map-in-hole" "$TMP/nested-map.pp" '"map 9"'

# (i) list value interpolation renders via string_of_value.
cat > "$TMP/list.pp" <<'EOF'
print(f"list is {[1, 2, 3]}")
EOF
run_ok "list-value-render" "$TMP/list.pp" '"list is (1 2 3)"'

# (j) quasiquote parity: a macro template containing an f-string with an
#     `unquote` hole builds the same interpolation after expansion.
cat > "$TMP/qq.pp" <<'EOF'
defmacro tag(label, val) {
  quasiquote {
    f"{unquote(label)}={unquote(val)}"
  }
}
print(tag("count", 42))
EOF
run_ok "fstring-in-quasiquote" "$TMP/qq.pp" '"count=42"'

# (k) empty interpolation {} is a clean error on both backends.
cat > "$TMP/emptyhole.pp" <<'EOF'
let x = 1
print(f"bad {} hole")
EOF
got_tw=$("$PP" "$TMP/emptyhole.pp" 2>&1 || true)
got_bc=$("$PP" --bytecode "$TMP/emptyhole.pp" 2>&1 || true)
if [[ "$got_tw" == *"empty interpolation"* ]] && [[ "$got_bc" == *"empty interpolation"* ]]; then
  ok "empty-hole-errors"
else
  bad "empty-hole-errors" "tw: $got_tw" "bc: $got_bc"
fi

# (l) f-strings round-trip through `pp fmt` hash-preserved (one-way desugar to
#     string-append/->string — the intermediate is a valid brace program).
cat > "$TMP/rt.ppb" <<'EOF'
def msg(n, who) { f"built {n} for {who}!" }
print(msg(3, "you"))
EOF
"$PP" fmt --to-sexpr "$TMP/rt.ppb" > "$TMP/rt.ppl" 2>"$TMP/rt.err"
"$PP" fmt --to-braces "$TMP/rt.ppl" > "$TMP/rt2.ppb" 2>>"$TMP/rt.err"
if "$PP" --compare-hash "$TMP/rt.ppb" "$TMP/rt2.ppb" >/dev/null 2>&1; then
  ok "fstring-fmt-hash-preserved"
else
  bad "fstring-fmt-hash-preserved" "$(cat "$TMP/rt.err")"
fi

exit $fail
