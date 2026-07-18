#!/usr/bin/env bash
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: $0 EXECUTABLE..." >&2; exit 2; }
passed=0
for executable in "$@"; do
  label=$(basename "$executable" .exe)
  home=$(mktemp -d)
  if HOME="$home" "$executable"; then
    passed=$((passed + 1))
  else
    rm -rf "$home"
    echo "focused tests: $label failed" >&2
    exit 1
  fi
  rm -rf "$home"
done
echo "focused tests: $passed executables passed"
