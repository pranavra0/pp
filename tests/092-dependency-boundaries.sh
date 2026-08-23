#!/usr/bin/env bash
# tests/092 — the accepted executable has no native build-tool dependency.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
cd "$ROOT"
[ -f lisp/pp.asd ]
[ -f scripts/build-lisp.sh ]
[ -x bin/pp ]
[ ! -e dune ]
[ ! -e dune-project ]
[ ! -e pp.opam ]
printf '%s\n' 'ok   dependency-boundary'
