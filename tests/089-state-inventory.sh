#!/usr/bin/env bash
# tests/089 — the production tree exposes only the Lisp package boundary.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
for path in \
  lisp/pp.asd \
  lisp/packages.lisp \
  lisp/kernel/core-model.lisp \
  lisp/frontend/frontend.lisp \
  lisp/runtime/evaluator.lisp \
  lisp/runtime/effects.lisp \
  lisp/app/main.lisp; do
  [ -f "$ROOT/$path" ] || { echo "FAIL missing Lisp source: $path" >&2; exit 1; }
done
[ ! -e "$ROOT/dune" ] || { echo 'FAIL obsolete build file remains' >&2; exit 1; }
[ ! -e "$ROOT/pp.opam" ] || { echo 'FAIL obsolete package file remains' >&2; exit 1; }

for package in pp.kernel pp.frontend pp.runtime pp.app; do
  grep -q "(defpackage #:$package" "$ROOT/lisp/packages.lisp" ||
    { echo "FAIL missing package boundary: $package" >&2; exit 1; }
done
for system in pp/kernel pp/frontend pp/runtime pp/app; do
  grep -q "(asdf:defsystem \"$system\"" "$ROOT/lisp/pp.asd" ||
    { echo "FAIL missing ASDF system: $system" >&2; exit 1; }
done
printf '%s\n' 'ok   lisp-boundary-inventory'
