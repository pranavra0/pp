#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
EXPORT=$(mktemp -d)
trap 'rm -rf "$EXPORT"' EXIT

if ! git -C "$ROOT" archive HEAD | tar -x -C "$EXPORT"; then
  printf '::error title=clean-export::failed to create clean archive (root=%s export=%s)\n' "$ROOT" "$EXPORT"
  exit 1
fi
if [ -e "$EXPORT/.git" ]; then
  printf '::error title=clean-export::clean export unexpectedly contains .git (export=%s)\n' "$EXPORT"
  exit 1
fi

cd "$EXPORT"
scripts/build-lisp.sh --output lisp/pp
TEST_JOBS="${TEST_JOBS:-1}" scripts/run-tests.sh bin/pp
./bin/pp --version > version.out
actual=$(sed -n 's/^pp v//p' version.out)
[ -n "$actual" ] || {
  printf 'clean-export: executable did not report a version\n' >&2
  exit 1
}
