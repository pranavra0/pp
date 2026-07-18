#!/usr/bin/env bash
# tests/089 — mutable-state inventory drift detector and deliberate-fixture gate.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$ROOT/scripts/check-state-inventory.sh"

baseline=$($CHECK --root "$ROOT" --src-dir "$ROOT/src" \
  --allowlist "$ROOT/scripts/state-inventory.allow")
grep -q '^mutable-field|src/core_model.ml|thunk_status$' <<<"$baseline"
grep -q '^lazy-env|src/store_layout.ml|crash_spec$' <<<"$baseline"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp -a "$ROOT/src" "$tmp/src"
cp "$ROOT/scripts/state-inventory.allow" "$tmp/state-inventory.allow"
printf 'let deliberate_fixture = ref 0\n' > "$tmp/src/deliberate_fixture.ml"

if $CHECK --root "$tmp" --src-dir "$tmp/src" \
    --allowlist "$tmp/state-inventory.allow" >"$tmp/out" 2>&1; then
  echo "FAIL state-inventory-drift: deliberate fixture was accepted" >&2
  exit 1
fi
grep -q 'top-ref|src/deliberate_fixture.ml|deliberate_fixture' "$tmp/out"
echo "ok   state-inventory-drift"
