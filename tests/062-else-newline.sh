#!/usr/bin/env bash
# tests/062 — `if`/`else` across a newline must not misparse.
#
# `parse_if` (and the quasiquote `if` handler in parse_qq_head) checked for
# `else` without first skipping a newline. Source written as:
#
#     if cond {
#       ...
#     }
#     else {
#       ...
#     }
#
# (the `}` and `else` on separate lines) silently parsed as an if WITHOUT an
# else, followed by a stray symbol `else` and an unrelated map literal — the
# else branch was dropped with no error. The fix makes the parser peek past
# newline(s) after the then-block and only consume them when `else` actually
# follows; if it doesn't, the newline is left alone so it can still terminate
# the statement.
#
# This is a differential test: every case must agree, byte for byte, between
# the tree-walker and the bytecode VM.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_case() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP" "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" \
        "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")" \
        "expected: $(printf '%q' "$expected")"
  fi
}

# Baseline: `} else {` on one line already worked before the fix.
cat > "$TMP/same-line.pp" <<'EOF'
let x = 1
if x = 1 {
  print("then")
} else {
  print("else")
}
EOF
run_case "else-same-line-baseline" "$TMP/same-line.pp" '"then"'

# The regression: `}` and `else` on separate lines. Before the fix this
# silently dropped the else branch (and, since `x = 2`, would print nothing
# from a dangling if, plus mis-evaluate the stray `else { print("else") }` as
# an unrelated map literal statement).
cat > "$TMP/split-line.pp" <<'EOF'
let x = 2
if x = 1 {
  print("then")
}
else {
  print("else")
}
EOF
run_case "else-across-newline-takes-else-branch" "$TMP/split-line.pp" '"else"'

# Same regression, but confirm the then-branch still fires (x = 1) with the
# split-line form, to be sure both sides of the branch parse correctly.
cat > "$TMP/split-line-then.pp" <<'EOF'
let x = 1
if x = 1 {
  print("then")
}
else {
  print("else")
}
EOF
run_case "else-across-newline-takes-then-branch" "$TMP/split-line-then.pp" '"then"'

# `else if` chains, each `}`/`else` split across a newline.
cat > "$TMP/chain.pp" <<'EOF'
let x = 3
if x = 1 {
  print("one")
}
else if x = 2 {
  print("two")
}
else {
  print("other")
}
EOF
run_case "else-if-chain-across-newlines" "$TMP/chain.pp" '"other"'

# An `if` with NO else, followed on the next line by an unrelated statement.
# The newline must NOT be wrongly consumed looking for a nonexistent else —
# the following statement must still run as its own statement.
cat > "$TMP/no-else.pp" <<'EOF'
let x = 1
if x = 1 {
  print("only-then")
}
print("after")
EOF
run_case "if-no-else-newline-not-swallowed" "$TMP/no-else.pp" $'"only-then"\n"after"'

# Same, but the if condition is false and there is no else: nothing from the
# if, then the following statement still runs.
cat > "$TMP/no-else-false.pp" <<'EOF'
let x = 2
if x = 1 {
  print("only-then")
}
print("after")
EOF
run_case "if-no-else-false-cond-newline-not-swallowed" "$TMP/no-else-false.pp" '"after"'

exit $fail
