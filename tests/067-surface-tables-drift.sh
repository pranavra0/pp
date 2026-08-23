#!/usr/bin/env bash
# tests/067 — generated surface data and ownership checks.
#
# The closed surface sets are defined in lisp/frontend/frontend.lisp. The
# generated SPEC block and the grant sugar must remain derived from that data.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SPEC="docs/SPEC.md"
BEGIN='<!-- BEGIN GENERATED surface-tables -->'
END='<!-- END GENERATED surface-tables -->'

# Generated SPEC block.
if [ ! -f "$SPEC" ]; then
  bad "spec-file-present" "docs/SPEC.md not found (cwd $(pwd))"
else
  in_block=$(awk -v b="$BEGIN" -v e="$END" '
    $0 == b { grab=1; next }
    $0 == e { grab=0 }
    grab    { print }' "$SPEC")
  generated=$("$PP" --dump-surface-tables)
  if [ -z "$in_block" ]; then
    bad "spec-markers-present" "no content between generated markers in $SPEC"
  elif [ "$in_block" = "$generated" ]; then
    ok "spec-block-matches-tables"
  else
    bad "spec-block-matches-tables" \
        "docs/SPEC.md §B.8 is stale — regenerate with:" \
        "  pp --dump-surface-tables  (paste between the markers)" \
        "--- diff (SPEC vs generated) ---"
    diff <(printf '%s\n' "$in_block") <(printf '%s\n' "$generated") | sed 's/^/     /'
  fi
fi

# Grant sugar is owned by the frontend surface table.
for d in "fs.read" "fs.write" "fs.rw"; do
  hits=$(grep -l -F "$d" lisp/frontend/*.lisp 2>/dev/null | sort)
  if [ "$hits" = "lisp/frontend/frontend.lisp" ]; then
    ok "single-source:$d"
  else
    bad "single-source:$d" \
        "expected '$d' only in lisp/frontend/frontend.lisp, found in:" \
        "$(printf '%s\n' "$hits" | sed 's/^/       /')"
  fi
done

# Builtins render from the catalog.
builtins=$($PP --dump-builtins)
if grep -q '^| builtin | arity | category |$' <<<"$builtins" \
    && [ "$(grep -c '^| `map` |' <<<"$builtins")" = 1 ] \
    && grep -q '^| `map` | 2 | collections |$' <<<"$builtins" \
    && ! grep -q 'ppc-' <<<"$builtins"; then
  ok "builtin-catalog-renders"
else
  bad "builtin-catalog-renders" "--dump-builtins did not match the descriptor catalog"
fi

exit $fail
