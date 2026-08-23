#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -f "$root/lisp/pp.asd" ] || { echo "architecture: missing lisp/pp.asd" >&2; exit 1; }
[ -f "$root/lisp/packages.lisp" ] || { echo "architecture: missing lisp/packages.lisp" >&2; exit 1; }
[ -f "$root/lisp/app/main.lisp" ] || { echo "architecture: missing lisp/app/main.lisp" >&2; exit 1; }
[ -x "$root/scripts/build-lisp.sh" ] || { echo "architecture: build-lisp.sh is not executable" >&2; exit 1; }

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/pp-architecture.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
"$root/scripts/build-lisp.sh" --output "$sandbox/pp" >/dev/null
HOME="$sandbox/home" "$sandbox/pp" --version >/dev/null
HOME="$sandbox/home" "$sandbox/pp" -e '1 + 2' >/dev/null
printf '%s\n' 'Architecture checks: all passed'
