#!/usr/bin/env bash
# Milestone 0 benchmark and golden-fixture runner.
# Every invocation requires an explicit engine binary; this script never starts a daemon.
set -euo pipefail
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 "$ROOT/scripts/benchmarks/m0.py" --root "$ROOT" "$@"
