#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXPORT=$(mktemp -d)
trap 'rm -rf "$EXPORT"' EXIT

# Archive and extract in a directory that cannot contain the checkout's .git.
git -C "$ROOT" archive HEAD | tar -x -C "$EXPORT"
[ ! -e "$EXPORT/.git" ] || { echo 'clean export unexpectedly contains .git' >&2; exit 1; }

if [ -n "${OPAM_SWITCH_PREFIX:-}" ] && [ -x "$OPAM_SWITCH_PREFIX/bin/dune" ]; then
  DUNE="$OPAM_SWITCH_PREFIX/bin/dune"
else
  DUNE="$(command -v dune)"
fi
cd "$EXPORT"
"$DUNE" build
"$DUNE" runtest --force
./_build/default/src/app/main.exe --version > version.out
expected=$(sed -nE 's/^[[:space:]]*\(version[[:space:]]+([^ )]+)\).*/\1/p' dune-project)
actual=$(sed -n 's/^pp v//p' version.out)
[ -n "$expected" ] || { echo 'could not parse version from dune-project' >&2; exit 1; }
[ "$actual" = "$expected" ] || {
  printf 'version mismatch: dune-project=%s executable=%s\n' "$expected" "$actual" >&2
  exit 1
}
