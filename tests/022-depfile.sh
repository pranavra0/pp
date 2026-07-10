#!/usr/bin/env bash
# Q2 refinement: the depfile adapter — precise cells below the coarse floor.
#
#   (perform run-dep DEPFILE CMD ARG...) runs like `run`, then parses the
#   Makefile-style depfile the tool wrote (cc -MD -MF style) and records the
#   EXACT files the tool read:
#     - a dep covered by an fs-read grant  → a precise `file:` cell
#     - a dep outside every grant (system) → a `tool:` cell (process authority)
#   and — the refinement — records NO coarse `tree:` cells, so touching an
#   unrelated file under a granted root no longer re-runs the node. If the
#   tool produced no depfile, the adapter falls back to the coarse floor
#   (tree: cells) — sound by default.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
SRC="$TMP/src"; OTHER="$TMP/other"
mkdir -p "$SRC" "$OTHER"
fail=0

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

printf 'H1\n'  > "$SRC/h1.txt"
printf 'S1\n'  > "$SRC/src1.txt"
printf 'U1\n'  > "$SRC/unrelated.txt"
printf 'SYS1\n' > "$OTHER/sys.txt"

# The "compiler": reads two granted inputs + one out-of-grant (system) input,
# writes its output and a truthful depfile into the sandbox cwd.
cat > "$TMP/c.pp" <<EOF
(perform log (force (node (do (perform log "COMPUTE")
  (do (perform run-dep "out.d" "sh" "-c"
        "cat $SRC/h1.txt $SRC/src1.txt $OTHER/sys.txt > out.txt; printf 'out.txt: $SRC/h1.txt $SRC/src1.txt $OTHER/sys.txt\\n' > out.d")
      (slurp "out.txt"))))))
EOF

G=(--grant process --grant "fs:$SRC:ro")

rm -rf "$TMP/.pp"
run "${G[@]}" "$TMP/c.pp"
assert "dep-run1-miss"      "COMPUTE" present
assert "dep-run1-value"     "H1"      present
run "${G[@]}" "$TMP/c.pp"
assert "dep-run2-hit"       "COMPUTE" absent

# --- THE REFINEMENT: an unrelated file under the granted root changes;
#     a coarse tree: cell would re-run, precise depfile cells must NOT ---
printf 'U2\n' > "$SRC/unrelated.txt"
run "${G[@]}" "$TMP/c.pp"
assert "dep-unrelated-still-hit" "COMPUTE" absent

# --- a dep the tool actually read changes ⇒ re-run (granted → file: cell) ---
printf 'H2\n' > "$SRC/h1.txt"
run "${G[@]}" "$TMP/c.pp"
assert "dep-header-stale"   "COMPUTE" present
assert "dep-header-value"   "H2"      present

# --- an OUT-OF-GRANT (system) dep changes ⇒ re-run (tool: cell) ---
printf 'SYS2\n' > "$OTHER/sys.txt"
run "${G[@]}" "$TMP/c.pp"
assert "dep-system-stale"   "COMPUTE" present
assert "dep-system-value"   "SYS2"    present

# --- no depfile produced ⇒ coarse fallback: unrelated change re-runs ---
cat > "$TMP/nodep.pp" <<EOF
(perform log (force (node (do (perform log "COMPUTE")
  (do (perform run-dep "missing.d" "sh" "-c"
        "cat $SRC/h1.txt > out.txt")
      (slurp "out.txt"))))))
EOF
rm -rf "$TMP/.pp"
run "${G[@]}" "$TMP/nodep.pp"
assert "fallback-run1-miss" "COMPUTE" present
printf 'U3\n' > "$SRC/unrelated.txt"
run "${G[@]}" "$TMP/nodep.pp"
assert "fallback-coarse-stale" "COMPUTE" present

# --- VM parity ---
rm -rf "$TMP/.pp"
printf 'U1\n' > "$SRC/unrelated.txt"
run --bytecode "${G[@]}" "$TMP/c.pp"
assert "vm-run1-miss"       "COMPUTE" present
run --bytecode "${G[@]}" "$TMP/c.pp"
assert "vm-run2-hit"        "COMPUTE" absent
printf 'U4\n' > "$SRC/unrelated.txt"
run --bytecode "${G[@]}" "$TMP/c.pp"
assert "vm-unrelated-still-hit" "COMPUTE" absent
printf 'H3\n' > "$SRC/h1.txt"
run --bytecode "${G[@]}" "$TMP/c.pp"
assert "vm-header-stale"    "COMPUTE" present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== DEPFILE ADAPTER (Q2) TEST PASSED ==="; fi
exit $fail
