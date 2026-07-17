#!/usr/bin/env bash
# tests/029 — REPL quality: the REPL now reads the brace surface by
# default. Covers the scriptable parts:
#   (a) multi-line input: a form left open continues onto following lines
#       (brace/paren/bracket/string nesting, comment-aware — see
#       Reader_braces.needs_more_input);
#   (b) definitions persist across lines;
#   (c) piped/non-tty sessions emit no prompts or banner — stdout is just
#       the printed values;
#   (d) :why toggles the node-cache explainer;
#   (e) exit(N) exits the REPL with status N;
#   (f) results print deep-forced (a delay shows its value, not #<thunk>).
# (Arrow-key editing and ~/.pp/history need a pty; verified by hand.)
# No .ppl/sexpr case here: the interactive REPL reads ONLY braces now —
# sexpr input has no interactive entry point to gate; cross-surface FILE
# loading is covered by tests/054.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
repl() {  # FLAGS... <<< input on stdin
  "$PP" "$@" 2>"$TMP/err"
}

# ---- (a) multi-line continuation ----
# an unclosed '(' holds the form open across lines (brace/paren/bracket
# nesting, per Reader_braces.needs_more_input); the whitespace-sensitive
# infix rule (`a - b` subtracts, `a-b` is a name) means an operator glued
# to the following newline (no trailing space) is its own separate matter —
# not what this case is testing, so the operator and both operands sit on
# one interior line and only the grouping parens span multiple lines.
got=$(printf '(\n1 + 2\n)\n' | repl)
if [ "$got" = "3" ]; then ok "multiline"
else bad "multiline" "got: $(printf '%q' "$got")"; fi
# strings and '#' comments don't confuse the balance
got=$(printf 'string-append("a(b", # comment\n"c)d")\n' | repl)
if [ "$got" = '"a(bc)d"' ]; then ok "multiline-string-comment"
else bad "multiline-string-comment" "got: $(printf '%q' "$got")"; fi
# a '{'-delimited block (a def body) holds the form open across lines too
got=$(printf 'def f(x) {\nx + 1\n}\nf(41)\n' | repl | tail -1)
if [ "$got" = "42" ]; then ok "multiline-block"
else bad "multiline-block" "got: $(printf '%q' "$got")"; fi

# ---- (g) continuation is decided by exception TYPE, not error-message text ----
# A genuine syntax error whose message happens to carry a magic word ("foo
# unterminated" -> "expected ...; got unterminated") must be reported at once,
# NOT mistaken for an open form — so a following valid line still evaluates.
# Under the old substring-matching classifier the "unterminated" in the message
# swallowed the whole buffer and 10 never appeared.
out=$(printf 'foo unterminated\n5 + 5\n' | repl)
if printf '%s\n' "$out" | grep -q '^10$' \
   && printf '%s\n' "$out" | grep -qi 'unterminated'; then
  ok "genuine-error-not-incomplete"
else bad "genuine-error-not-incomplete" "out: $(printf '%q' "$out")"; fi
# An unclosed form submitted at end of input surfaces as a normal located
# reader error (not the raw OCaml exception), so the message decouples from the
# exception mechanism.
got=$(printf 'def foo\n' | repl 2>&1)
if printf '%s\n' "$got" | grep -q 'def requires a parameter list' \
   && ! printf '%s\n' "$got" | grep -q 'Reader_incomplete'; then
  ok "incomplete-at-eof-clean-error"
else bad "incomplete-at-eof-clean-error" "got: $(printf '%q' "$got")"; fi

# ---- (b) defs persist across lines ----
got=$(printf 'let x = 21\nprint(x * 2)\n' | repl | tail -1)
if [ "$got" = "nil" ]; then :; fi
got=$(printf 'let x = 21\nx * 2\n' | repl | tail -1)
if [ "$got" = "42" ]; then ok "defs-persist"
else bad "defs-persist" "got: $(printf '%q' "$got")"; fi

# ---- (c) no prompts/banner when piped ----
got=$(printf '1 + 2\n' | repl)
if [ "$got" = "3" ]; then ok "no-prompt-when-piped"
else bad "no-prompt-when-piped" "got: $(printf '%q' "$got")"; fi

# ---- (d) :why toggle ----
rm -rf "$TMP/.pp"
printf ':why on\nforce(node { 40 + 2 })\n' | repl > "$TMP/out"
if grep -q "\[why\]" "$TMP/err" && grep -q "^42$" "$TMP/out"; then ok "why-toggle"
else bad "why-toggle" "out: $(cat "$TMP/out")" "err: $(cat "$TMP/err")"; fi

# ---- (e) exit code control in the REPL ----
ec=0; printf 'exit(4)\n' | repl || ec=$?
if [ "$ec" -eq 4 ]; then ok "repl-exit-code"
else bad "repl-exit-code" "exit=$ec"; fi

# ---- (f) deep-forced printing ----
got=$(printf 'delay(1 + 2)\n' | repl)
if [ "$got" = "3" ]; then ok "deep-forced-printing"
else bad "deep-forced-printing" "got: $(printf '%q' "$got")"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== REPL TEST PASSED ==="; fi
exit $fail
