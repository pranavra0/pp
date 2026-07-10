#!/usr/bin/env bash
# tests/029 — REPL quality (ROADMAP §1): the scriptable parts.
#   (a) multi-line input: a form left open continues onto following lines
#       (paren balance, string- and comment-aware), both backends;
#   (b) definitions persist across lines (including in the VM REPL, which
#       used to reset its globals on every line);
#   (c) piped/non-tty sessions emit no prompts or banner — stdout is just
#       the printed values;
#   (d) :why toggles the node-cache explainer;
#   (e) (exit N) exits the REPL with status N;
#   (f) results print deep-forced (a delay shows its value, not #<thunk>).
# (Arrow-key editing and ~/.pp/history need a pty; verified by hand.)
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

repl() {  # FLAGS... <<< input on stdin
  "$PP" "$@" 2>"$TMP/err"
}

# ---- (a) multi-line continuation ----
for flags in "" "--bytecode"; do
  got=$(printf '(+ 1\n2)\n' | repl $flags)
  if [ "$got" = "3" ]; then ok "multiline${flags:+-vm}"
  else bad "multiline${flags:+-vm}" "got: $(printf '%q' "$got")"; fi
done
# strings and comments don't confuse the balance
got=$(printf '(string-append "a(b" ; comment )\n"c)d")\n' | repl)
if [ "$got" = '"a(bc)d"' ]; then ok "multiline-string-comment"
else bad "multiline-string-comment" "got: $(printf '%q' "$got")"; fi

# ---- (b) defs persist across lines ----
for flags in "" "--bytecode"; do
  got=$(printf '(def x 21)\n(print (* x 2))\n' | repl $flags | tail -1)
  if [ "$got" = "nil" ]; then :; fi
  got=$(printf '(def x 21)\n(* x 2)\n' | repl $flags | tail -1)
  if [ "$got" = "42" ]; then ok "defs-persist${flags:+-vm}"
  else bad "defs-persist${flags:+-vm}" "got: $(printf '%q' "$got")"; fi
done

# ---- (c) no prompts/banner when piped ----
got=$(printf '(+ 1 2)\n' | repl)
if [ "$got" = "3" ]; then ok "no-prompt-when-piped"
else bad "no-prompt-when-piped" "got: $(printf '%q' "$got")"; fi

# ---- (d) :why toggle ----
rm -rf "$TMP/.pp"
printf ':why on\n(force (node (+ 40 2)))\n' | repl > "$TMP/out"
if grep -q "\[why\]" "$TMP/err" && grep -q "^42$" "$TMP/out"; then ok "why-toggle"
else bad "why-toggle" "out: $(cat "$TMP/out")" "err: $(cat "$TMP/err")"; fi

# ---- (e) exit code control in the REPL ----
ec=0; printf '(exit 4)\n' | repl || ec=$?
if [ "$ec" -eq 4 ]; then ok "repl-exit-code"
else bad "repl-exit-code" "exit=$ec"; fi

# ---- (f) deep-forced printing ----
got=$(printf '(delay (+ 1 2))\n' | repl)
if [ "$got" = "3" ]; then ok "deep-forced-printing"
else bad "deep-forced-printing" "got: $(printf '%q' "$got")"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== REPL TEST PASSED ==="; fi
exit $fail
