#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
unit=$(find "$root/tests/unit" -maxdepth 1 -type f -name '*_unit.ml' | wc -l)
language=$(find "$root/tests" -maxdepth 1 -type f -name '[0-9]*.pp' | wc -l)
integration=$(find "$root/tests" -maxdepth 1 -type f -name '*.sh' ! -name 'lib.sh' | wc -l)
sensitive=$(find "$root/tests" -maxdepth 1 -type f \( -name '009*.pp' -o -name '01[0-9]*.sh' -o -name '02[0-4]*.sh' \) | wc -l)
gates=$(find "$root/tests" -maxdepth 1 -type f -name '09[0-4]*.sh' | wc -l)
printf 'test categories: unit=%s language=%s integration=%s architecture-gates=%s sensitive=%s\n' \
  "$unit" "$language" "$integration" "$gates" "$sensitive"
