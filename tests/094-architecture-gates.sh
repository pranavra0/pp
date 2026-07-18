#!/usr/bin/env bash
# Controlled violations prove that each permanent architecture gate is live;
# all probes stay in a temporary copy and are removed on exit.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

must_fail() {
  local name=$1; shift
  if "$@" >"$TMP/$name.out" 2>&1; then
    echo "FAIL $name accepted a controlled violation" >&2
    cat "$TMP/$name.out" >&2
    exit 1
  fi
  echo "ok   $name"
}

awk '!/-warn-error[[:space:]]/' "$ROOT/dune" > "$TMP/dune-no-fatal-warnings"
must_fail compiler-warnings \
  bash "$ROOT/tools/check-compiler-warnings.sh" --dune-file "$TMP/dune-no-fatal-warnings"

awk -F: 'BEGIN { OFS=":" } $1 == "frontend" {$2="pp.runtime"} {print}' \
  "$ROOT/tools/dependency-manifest" > "$TMP/bad-dependency-manifest"
must_fail dependency-direction \
  bash "$ROOT/tools/check-dependencies.sh" --root "$ROOT" --manifest "$TMP/bad-dependency-manifest"

mkdir -p "$TMP/state/src"
cp -a "$ROOT/src/." "$TMP/state/src/"
cp "$ROOT/scripts/state-inventory.allow" "$TMP/state/allow"
printf 'let architecture_fixture = ref 0\n' > "$TMP/state/src/architecture_fixture.ml"
must_fail mutable-state \
  bash "$ROOT/scripts/check-state-inventory.sh" --root "$TMP/state" \
    --src-dir "$TMP/state/src" --allowlist "$TMP/state/allow"

mkdir -p "$TMP/api/src"
cp -a "$ROOT/src/." "$TMP/api/src/"
chmod -R u+rw "$TMP/api"
cp "$ROOT/tools/api-surface.allow" "$TMP/api.allow"
printf 'val architecture_fixture : unit\n' >> "$TMP/api/src/kernel/version.mli"
must_fail api-surface \
  bash "$ROOT/tools/check-api-surface.sh" --root "$TMP/api" --manifest "$TMP/api.allow"

mkdir -p "$TMP/slices/src" "$TMP/slices/tools"
cp -a "$ROOT/src/." "$TMP/slices/src/"
cp "$ROOT/tools/fuzz.ml" "$TMP/slices/tools/fuzz.ml"
chmod -R u+rw "$TMP/slices"
awk '{gsub(/ELiteral/, ""); print}' "$TMP/slices/src/frontend/reader.ml" \
  > "$TMP/slices/src/frontend/reader.ml.tmp"
mv "$TMP/slices/src/frontend/reader.ml.tmp" "$TMP/slices/src/frontend/reader.ml"
printf '(* ELiteral *)\n' >> "$TMP/slices/src/frontend/reader.ml"
must_fail vertical-slice \
  bash "$ROOT/tools/check-vertical-slices.sh" --root "$TMP/slices"

echo "architecture gates: controlled violations rejected and reverted"
