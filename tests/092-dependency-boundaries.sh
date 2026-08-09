#!/usr/bin/env bash
# The physical library graph is checked independently of the full suite.
set -euo pipefail
ROOT="${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$ROOT"
bash tools/check-dependencies.sh
