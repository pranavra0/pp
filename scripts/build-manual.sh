#!/usr/bin/env bash
# Build the pp reference manual — with pp.
#
# docs/manual/build.pp runs every code example through pp (capturing its real
# output) and invokes typst as hermetic tool nodes to typeset docs/manual/site/
# (index.html + pp-manual.pdf). Incremental: an unchanged manual re-runs neither
# the examples nor the typesetter.
#
# Run from the repo root, outside dune. Needs `typst` on PATH.
set -uo pipefail
cd "$(dirname "$0")/.."
PP=${PP:-"$PWD/bin/pp"}
[ -x "$PP" ] || PP="$PWD/_build/default/src/main.exe"
command -v typst >/dev/null || { echo "SKIPPED (no typst on PATH)"; exit 0; }

MANUAL="$PWD/docs/manual"
"$PP" "$MANUAL/build.pp" \
  --grant "fs:$MANUAL:rw" \
  --grant process \
  -- "$MANUAL" "$PP"

echo "-- open $MANUAL/site/index.html"
