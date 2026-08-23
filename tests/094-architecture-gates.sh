#!/usr/bin/env bash
# tests/094 — the executable boundary and saved-image architecture checks.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
"$ROOT/scripts/check-architecture.sh"
printf '%s\n' 'ok   architecture-gates'
