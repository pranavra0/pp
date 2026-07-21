#!/usr/bin/env bash
# tests/067 — SPEC drift test + single-source grep check.
#
# The closed surface sets (observation `$KIND` heads, `with{}` clause keywords,
# `needs` grant-descriptor sugar) are one typed value each in
# src/frontend/surface_tables.ml. Two ratchets keep every derived copy honest:
#
#   (1) SPEC drift — docs/SPEC.md carries a *generated* block between
#       markers. `pp --dump-surface-tables` regenerates it; this test diffs.
#       A table edit not mirrored into SPEC is a red build.
#
#   (2) Single source — the grant descriptors (`fs.read`/`fs.write`/`fs.rw`)
#       must appear in exactly one .ml file (surface_tables.ml). A hand-copy
#       re-introduced in the reader/lint/fuzzer would fail here. (The `$`-head
#       and `caps:`/`config:`/`handler` keyword strings overlap the
#       cell-literal syntax and the `config` reserved word respectively, so
#       this grep is scoped to the grant set — the one set with no other
#       legitimate use; the drift test (1) covers all three tables' content.)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SPEC="docs/SPEC.md"
BEGIN='<!-- BEGIN GENERATED surface-tables -->'
END='<!-- END GENERATED surface-tables -->'

# (1) SPEC drift.
if [ ! -f "$SPEC" ]; then
  bad "spec-file-present" "docs/SPEC.md not found (cwd $(pwd))"
else
  # Extract lines strictly between the markers.
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

# (2) Single source: grant descriptors live only in surface_tables.ml.
for d in "fs.read" "fs.write" "fs.rw"; do
  hits=$(grep -l -F "$d" src/frontend/*.ml 2>/dev/null | sort)
  if [ "$hits" = "src/frontend/surface_tables.ml" ]; then
    ok "single-source:$d"
  else
    bad "single-source:$d" \
        "expected '$d' only in src/frontend/surface_tables.ml, found in:" \
        "$(printf '%s\n' "$hits" | sed 's/^/       /')"
  fi
done

# (3) Builtin inventory: the user-facing inventory is rendered from the
# descriptor catalog, so a registration cannot silently disappear from the
# generated table or appear twice.
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
