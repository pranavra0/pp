#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
bash "$root/tools/check-compiler-warnings.sh" --dune-file "$root/dune"
bash "$root/tools/check-dependencies.sh" --root "$root" --manifest "$root/tools/dependency-manifest"
bash "$root/scripts/check-state-inventory.sh" --root "$root" --src-dir "$root/src" --allowlist "$root/scripts/state-inventory.allow" >/dev/null
bash "$root/tools/check-api-surface.sh" --root "$root" --manifest "$root/tools/api-surface.allow"
bash "$root/tools/check-vertical-slices.sh" --root "$root"
echo "Architecture gates: all passed"
