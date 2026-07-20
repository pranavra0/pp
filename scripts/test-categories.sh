#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
unit=0
for file in "$root/tests/unit"/*_unit.ml; do
  [ -f "$file" ] && unit=$((unit + 1))
done

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
printf 'test categories: unit=%s language=%s integration=%s architecture-gates=%s sensitive=%s\n' \
  "$unit" "$language" "$integration" "$gates" "$sensitive"
