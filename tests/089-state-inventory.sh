#!/usr/bin/env bash
# tests/089 — the production tree contains only the accepted Lisp boundary.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ ! -d "$ROOT/src" ] || { echo 'FAIL obsolete source tree remains' >&2; exit 1; }
[ ! -e "$ROOT/dune" ] || { echo 'FAIL obsolete build file remains' >&2; exit 1; }
[ ! -e "$ROOT/pp.opam" ] || { echo 'FAIL obsolete package file remains' >&2; exit 1; }
[ -f "$ROOT/lisp/pp.asd" ]
[ -f "$ROOT/lisp/app/main.lisp" ]
printf '%s\n' 'ok   lisp-boundary-inventory'
