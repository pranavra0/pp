#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
dune_file="$root/dune"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dune-file) dune_file=$2; shift 2 ;;
    *) echo "usage: $0 [--dune-file FILE]" >&2; exit 2 ;;
  esac
done

[ -f "$dune_file" ] || {
  echo "compiler warnings: dune file not found: $dune_file" >&2
  exit 1
}

if ! grep -Eq -- '-warn-error[[:space:]]' "$dune_file"; then
  echo "compiler warnings: dev flags do not make warnings fatal" >&2
  exit 1
fi

echo "compiler warnings: fatal"
