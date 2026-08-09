#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXPORT=$(mktemp -d)
trap 'rm -rf "$EXPORT"' EXIT

# Archive and extract in a directory that cannot contain the checkout's .git.
if ! git -C "$ROOT" archive HEAD | tar -x -C "$EXPORT"; then
  printf '::error title=clean-export::failed to create clean archive (root=%s export=%s)\n' "$ROOT" "$EXPORT"
  exit 1
fi
if [ -e "$EXPORT/.git" ]; then
  printf '::error title=clean-export::clean export unexpectedly contains .git (export=%s)\n' "$EXPORT"
  exit 1
fi

if command -v opam >/dev/null 2>&1; then
  DUNE=(opam exec -- dune)
elif DUNE=$(command -v dune 2>/dev/null); then
  DUNE=("$DUNE")
else
  printf '::error title=clean-export::could not locate dune (root=%s export=%s)\n' "$ROOT" "$EXPORT"
  exit 1
fi
cd "$EXPORT"
"${DUNE[@]}" build
"${DUNE[@]}" runtest --force
./_build/default/src/app/main.exe --version > version.out
expected=$(sed -nE 's/^[[:space:]]*\(version[[:space:]]+([^ )]+)\).*/\1/p' dune-project)
actual=$(sed -n 's/^pp v//p' version.out)
[ -n "$expected" ] || { echo 'could not parse version from dune-project' >&2; exit 1; }
[ "$actual" = "$expected" ] || {
  printf 'version mismatch: dune-project=%s executable=%s\n' "$expected" "$actual" >&2
  exit 1
}
