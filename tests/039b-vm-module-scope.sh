#!/usr/bin/env bash
# tests/039b — D23: VM module scope leak. Inline `module { ... }` must run
# with isolated globals, matching `eval_module_from` for file-loaded modules.
# The tree-walker is the oracle: a module body must NOT see enclosing top-level
# `let` bindings (or any enclosing lexical scope). This test is differential:
# both backends must produce byte-identical output.
#
# Pins: D23 (module scope isolation), D22 (existing module-sibling visibility).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_both() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP"            "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "tw:       $(printf '%q' "$got_tw")" "bc:       $(printf '%q' "$got_bc")"
  fi
}

run_both_err() {
  local name="$1" file="$2" pat="$3"
  local got_tw got_bc
  got_tw=$("$PP"            "$file" 2>&1 || true)
  got_bc=$("$PP" --bytecode "$file" 2>&1 || true)
  if echo "$got_tw" | grep -qE "$pat" && echo "$got_bc" | grep -qE "$pat"; then
    ok "$name"
  else
    bad "$name" "expected pattern: $pat" \
        "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
  fi
}

# (a) top-level let must not leak into inline module body
cat > "$TMP/a.pp" <<'EOF'
let x = 1
import(module { let y = x })
EOF
run_both_err "top-level-let-no-leak" "$TMP/a.pp" "unbound symbol"

# (b) do-block let must not leak into module body
cat > "$TMP/b.pp" <<'EOF'
let z = 1
do { import(module { let w = z }) }
EOF
run_both_err "do-let-no-leak" "$TMP/b.pp" "unbound symbol"

# (c) function-scope let must not leak into module body
cat > "$TMP/c.pp" <<'EOF'
def f() { let z = 1; import(module { let w = z }) }
f()
EOF
run_both_err "fn-let-no-leak" "$TMP/c.pp" "unbound symbol"

# (d) nested inline modules: each module has its own fresh scope;
#     outer module defs are visible inside the outer module's own
#     body (so a sibling expression referencing them works).
cat > "$TMP/d.pp" <<'EOF'
import(module {
  let a = 1
  let b = a + 1
  print(b)
})
EOF
run_both "module-sibling-visibility" "$TMP/d.pp" '2'

# (e) import inside a module merges the imported module's exports
cat > "$TMP/e1.pp" <<'EOF'
def inc(x) { x + 1 }
let version = 42
EOF
cat > "$TMP/e2.pp" <<EOF
import(module {
  import(load-module("$TMP/e1.pp"))
  let result = inc(version)
  print(result)
})
EOF
run_both "import-in-module" "$TMP/e2.pp" '43'

rm -rf "$TMP"
exit $fail
