#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
language=0
for file in "$root/tests"/[0-9]*.pp; do
  [ -f "$file" ] && language=$((language + 1))
done

integration=0
for file in "$root/tests"/*.sh; do
  [ -f "$file" ] || continue
  [ "$(basename "$file")" = "lib.sh" ] || integration=$((integration + 1))
done

sensitive=0
for file in "$root/tests"/009*.pp "$root/tests"/01[0-9]*.sh "$root/tests"/02[0-4]*.sh; do
  [ -f "$file" ] && sensitive=$((sensitive + 1))
done

gates=0
for file in "$root/tests"/09[0-4]*.sh; do
  [ -f "$file" ] && gates=$((gates + 1))
done
printf 'test categories: language=%s integration=%s architecture-gates=%s sensitive=%s\n' \
  "$language" "$integration" "$gates" "$sensitive"
