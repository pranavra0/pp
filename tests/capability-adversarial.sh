#!/usr/bin/env bash
# pins: LAW-22 LAW-22b LAW-25 LAW-27
# Adversarial capability suite: capabilities can only enter a program through
# --grant (filesystem/network/process are not user-code constructors any
# more), and in-language attenuation (cap-restrict/cap-compose/with-caps) can
# only narrow what's already held, never widen or invent authority.
# Runs the tree-walker on every case.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
trap 'rm -rf "$TMP"' EXIT
# The node-boundary cases below use (node ...); isolate the store like
# tests/011/013/017 do. Harmless for the pre-existing scripting-tier cases
# above, which never touch ~/.pp/store.

run_case() {
  local name="$1"; shift
  local expected="$1"; shift
  local out="$TMP/out-$name.out"
  "$PP" "$@" > "$out" 2>&1 || true
  if grep -qE "$expected" "$out"; then
    echo "ok $name"
  else
    echo "FAIL $name: expected '$expected'"
    cat "$out"
    return 1
  fi
}

# Positive: --grant gives read access to /tmp but not /tmpevil.
echo "pp-cap-allowed" > "$TMP/allowed.txt"
cp "$TMP/allowed.txt" /tmp/pp-cap-test-file 2>/dev/null || true

cat > "$TMP/read-allowed.pp" <<'EOF'
print(slurp("/tmp/pp-cap-test-file"))
EOF
run_case read-allowed "pp-cap-allowed" "$TMP/read-allowed.pp" --grant fs:/tmp:ro

# Negative: path-component scope — /tmp must NOT grant /tmpevil.
cat > "$TMP/read-denied.pp" <<'EOF'
print(slurp("/tmpevil/secret"))
EOF
run_case path-component-denied "slurp: permission denied" "$TMP/read-denied.pp" --grant fs:/tmp:ro

# Negative: capability constructors removed from user code.
run_case constructor-filesystem "unbound.*filesystem" -e 'print(filesystem("/", :rw))'
run_case constructor-network     "unbound.*network"     -e 'print(network(:any))'
run_case constructor-process     "unbound.*process"     -e 'print(process())'

# Negative: read-file without any grant.
run_case read-no-grant "capability error: no read access" -e 'print(perform read-file("/etc/hostname"))'

# Positive: cap-restrict and cap-compose work on an already-granted cap.
cat > "$TMP/cap-ops.pp" <<'EOF'
let (sub = cap-restrict(cap-compose(cap-none(), cap-none()), "x")) {
  print("restricted:", sub)
}
EOF
run_case cap-ops "restricted:" "$TMP/cap-ops.pp"

# ============================================================
# In-language capability attenuation: narrowing, composing, and the node
# boundary can never be used to gain authority beyond what was granted.
# ============================================================

# --- forge-from-print: a printed capability is inert text; nothing reads a
#     `#<cap ...>` token back into a value. Under the brace surface `#`
#     starts a comment (not the sexpr reader's dedicated "unexpected
#     character after #" error token) — so the STRONGER guarantee now holds:
#     the printed form is not merely a parse error, it is syntactically
#     invisible (a whole line of it vanishes, same as any other comment),
#     which is still exactly "cannot be read back into a capability by any
#     means". Sentinels on both sides confirm the line in between is
#     swallowed without incident (no value, no binding, no error). ---
out=$("$PP" -e 'print("before")
#<cap compose 1>
print("after")' 2>&1)
want=$'"before"\n"after"\nnil\nnil'
if [ "$out" = "$want" ]; then
  ok "forge-from-print-is-comment"
else
  bad "forge-from-print-is-comment" "got: $(printf '%q' "$out")" "want: $(printf '%q' "$want")"
fi

# --- compose-does-not-resurrect: two narrowed views of the SAME broad root,
#     composed, grant only their union — not the root's full authority. ---
mkdir -p "$TMP/cdnr/a" "$TMP/cdnr/b" "$TMP/cdnr/secret"
printf 'SECRETDATA\n' > "$TMP/cdnr/secret/x.txt"
cat > "$TMP/compose-no-resurrect.pp" <<EOF
with-caps(cap-compose(cap-restrict(current-capabilities(), "$TMP/cdnr/a", :ro), cap-restrict(current-capabilities(), "$TMP/cdnr/b", :ro))) {
  print(slurp("$TMP/cdnr/secret/x.txt"))
}
EOF
run_case compose-does-not-resurrect "permission denied" "$TMP/compose-no-resurrect.pp" --grant "fs:$TMP/cdnr:ro"

# --- cap-restrict-mode-widen-rejected: requesting :rw on a cap that only
#     holds :ro at that scope is a Capability_error, never a silent widen. ---
run_case cap-restrict-mode-widen-rejected "cannot widen mode" \
  -e 'cap-restrict(current-capabilities(), "/tmp", :rw)' --grant fs:/tmp:ro

# --- with-caps-widen-rejected: a lexically-held BROAD value fails the ⊆
#     check when used INSIDE a narrowed with-caps extent — the gate runs
#     against the CURRENT ambient, not the root grant. ---
mkdir -p "$TMP/wwr/sub"
WWR_SRC="let broad = current-capabilities()
with-caps(cap-restrict(broad, \"$TMP/wwr/sub\", :ro)) {
  with-caps(broad) { print(\"leak\") }
}"
run_case with-caps-widen-rejected "requested capability is not a subset" \
  -e "$WWR_SRC" --grant "fs:$TMP/wwr:ro"

# --- with-caps tail-safe / exception-safe (SPEC law 27): a narrowed
#     with-caps extent, whether it exits via a tail call or a raised error,
#     must not leak the narrowing past the form. Both need multiple
#     top-level forms observing each other's ambient, which requires a
#     PERSISTENT session (REPL over piped stdin) — a one-shot `pp file`
#     aborts entirely on the first uncaught error, so exception-recovery
#     cannot be observed within a single non-REPL invocation. ---
mkdir -p "$TMP/wcex/a" "$TMP/wcex/secret"
printf 'SECRETDATA\n' > "$TMP/wcex/secret/s.txt"

run_repl_case() {  # NAME  INPUT  EXPECTED_REGEX  [extra pp args...]
  local name="$1" input="$2" expected="$3"; shift 3
  local out="$TMP/out-$name.out"
  printf '%s\n' "$input" | "$PP" "$@" > "$out" 2>&1 || true
  if grep -qE "$expected" "$out"; then
    echo "ok $name"
  else
    echo "FAIL $name: expected '$expected'"
    cat "$out"
    return 1
  fi
}

WC_EXC_INPUT="with-caps(cap-restrict(current-capabilities(), \"$TMP/wcex/a\", :ro)) { error(\"boom\") }
print(slurp(\"$TMP/wcex/secret/s.txt\"))"
run_repl_case with-caps-exception-safe "$WC_EXC_INPUT" "SECRETDATA" --grant "fs:$TMP/wcex:ro"

WC_TAIL_INPUT="def id(x) { x }
with-caps(cap-restrict(current-capabilities(), \"$TMP/wcex/a\", :ro)) { id(1) }
print(slurp(\"$TMP/wcex/secret/s.txt\"))"
run_repl_case with-caps-tail-safe "$WC_TAIL_INPUT" "SECRETDATA" --grant "fs:$TMP/wcex:ro"

# --- node-cap-capture-direct (layer 1: free-var ban, import side): a node
#     whose free variable IS a capability value must not be key-able. ---
cat > "$TMP/node-cap-direct.pp" <<'EOF'
let c = current-capabilities()
force(node { c })
EOF
run_case node-cap-capture-direct "may not be or contain a capability" "$TMP/node-cap-direct.pp"

# --- node-cap-capture-via-closure (layer 1, closure-env-aware): a node whose
#     free variable is a CLOSURE that captured a capability (as a parameter,
#     so it lands in the closure's frame/env) is
#     equally banned — the ban is structural, not "top of the value only". ---
cat > "$TMP/node-cap-closure.pp" <<'EOF'
def mk(cap) { fn() { cap } }
let clos = mk(current-capabilities())
force(node { clos() })
EOF
run_case node-cap-capture-via-closure "may not be or contain a capability" "$TMP/node-cap-closure.pp"

# --- node-cap-observation-rejected: public authority inspection is scripting
#     tier only. The `needs` reader sugar uses a private projection so explicit
#     node authority still works without leaving an ambient observation hole. ---
run_case node-cap-observation-rejected \
  "current-capabilities: may not be called inside a node body" \
  -e 'force(node { current-capabilities() })'
run_case node-cap-observation-embedded \
  "current-capabilities: may not be called inside a node body" \
  -e 'force(node { list(1, current-capabilities()) })'

# --- effect-removed: the `effect` special form no longer exists; `effect()`
#     is now an ordinary (unbound) function call. `with-handler`/`perform`
#     are unaffected. ---
run_case effect-removed "unbound symbol: effect" -e 'effect()'

echo "=== ALL ADVERSARIAL TESTS PASSED ==="
