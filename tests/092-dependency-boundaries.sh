#!/usr/bin/env bash
# The physical library graph is checked independently of the full suite.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tools/check-dependencies.sh
