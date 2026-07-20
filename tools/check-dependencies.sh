#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
manifest="$script_dir/dependency-manifest"

usage() {
  echo "usage: $0 [--root DIR] [--manifest FILE]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    --manifest) manifest=$2; shift 2 ;;
    *) usage ;;
  esac
done

src_root="$root/src"
status=0

while IFS=: read -r layer expected; do
  [[ -z "${layer//[[:space:]]/}" || "$layer" == \#* ]] && continue
  expected="${expected# }"
  dune_file="$src_root/$layer/dune"
  actual=$(sed -n '1,/^(executable/p' "$dune_file" |
    sed -n 's/.*(libraries \([^)]*\)).*/\1/p' |
    head -1 | tr -s ' ' | sed 's/^ //; s/ $//')
  if [[ "$actual" != "$expected" ]]; then
    printf 'dependency boundary: %s links [%s], expected [%s]\n' \
      "$layer" "$actual" "$expected" >&2
    status=1
  fi
  grep -q '(wrapped true)' "$dune_file" || {
    printf 'dependency boundary: %s is not wrapped\n' "$layer" >&2
    status=1
  }
done < "$manifest"

for layer in kernel frontend; do
  for source in "$src_root/$layer"/*.ml \
                "$src_root/$layer"/*.mli; do
    if ocamldep -modules "$source" 2>/dev/null | grep -qw Unix; then
      printf 'dependency boundary: %s links Unix through %s\n' \
        "$layer" "$(basename "$source")" >&2
      status=1
    fi
  done
done

exit "$status"
