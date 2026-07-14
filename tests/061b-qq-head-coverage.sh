#!/usr/bin/env bash
# tests/061b — A3 CI rule: every parse_head arm has quasiquote parity (is
# handled in parse_qq_head) or is an explicitly documented exclusion here.
#
# This is deliberately lightweight (a grep-based structural check over
# src/reader_braces.ml, not a semantic one): it extracts the head-word
# string literal each `parse_head`/`parse_qq_head` match arm dispatches on
# (a `|` immediately followed by `"word"` or a `("a" | "b" | ...)` group,
# immediately followed by `when`/`->` — the shape every real dispatch arm
# in this file has; error-message strings inside an arm's BODY never sit
# directly after a bare `|`, so they don't get picked up) and asserts the
# normal-parser set is a subset of the qq-parser set, modulo EXCLUDED below.
#
# The point (A3's ask): a future PR that adds a new block/sugar form to
# parse_head without EITHER lifting it into parse_qq_head OR adding it here
# should fail this test, not silently ship an unrepresentable form.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/reader_braces.ml"
fail=0

# Known, PRE-EXISTING qq gaps — not part of A3's mandate (try/match/m[k]/
# list-spread), so not implemented here. Each is a real parse_head arm with
# no parse_qq_head counterpart today:
#   fenced   — fenced :kind { ... } (lowers to perform("fenced", ...))
#   with     — with { caps: C, config: M, handlers: M } { body } combo
#              sugar (the PRIMITIVE forms with-caps/with-config/with-handler
#              it desugars to already have qq arms; this convenience
#              wrapper itself does not)
#   vec      — vec[...] vector literal with spread (only the bracket LIST
#              literal `[...]` got A2/A3 qq parity, not `vec[...]`)
# (B6 removed `cond` and B2 removed `collect` from parse_head — both dropped.)
# A future fix that lifts one of these should DELETE it from this list —
# the extraction below will then find it covered and the assertion holds.
EXCLUDED="fenced with vec"

extract() {
  # $1: start line, $2: end line (inclusive) of the function body to scan.
  sed -n "${1},${2}p" "$SRC" | tr '\n' ' ' \
    | grep -oE '\|[[:space:]]*("[A-Za-z*_-]+"|\([^()]*\))[[:space:]]*(when|->)' \
    | grep -oE '"[A-Za-z*_-]+"' | tr -d '"' | sort -u
}

head_start=$(grep -n '^and parse_head ps' "$SRC" | head -1 | cut -d: -f1)
head_end=$(grep -n '^and needs_restrict' "$SRC" | head -1 | cut -d: -f1)
qq_start=$(grep -n '^and parse_qq_head ps' "$SRC" | head -1 | cut -d: -f1)
qq_end=$(grep -n '^and parse_qq_cond ps' "$SRC" | head -1 | cut -d: -f1)

if [ -z "$head_start" ] || [ -z "$head_end" ] || [ -z "$qq_start" ] || [ -z "$qq_end" ]; then
  echo "FAIL 061b-qq-head-coverage  (could not locate parse_head/parse_qq_head" \
       "function boundaries in $SRC — source moved; update this test's markers)"
  exit 1
fi

normal_heads=$(extract "$head_start" "$((head_end - 1))")
qq_heads=$(extract "$qq_start" "$((qq_end - 1))")

if [ -z "$normal_heads" ]; then
  echo "FAIL 061b-qq-head-coverage  (extracted zero parse_head heads — regex is" \
       "no longer matching this file's style; update the extraction)"
  exit 1
fi

missing=""
for w in $normal_heads; do
  if ! grep -qx "$w" <<< "$qq_heads"; then
    case " $EXCLUDED " in
      *" $w "*) : ;;  # documented exclusion above
      *) missing="$missing $w" ;;
    esac
  fi
done

if [ -z "$missing" ]; then
  echo "ok   061b-qq-head-coverage"
else
  echo "FAIL 061b-qq-head-coverage  (parse_head arm(s) with no quasiquote parity" \
       "and no exclusion:$missing)"
  fail=1
fi

exit $fail
