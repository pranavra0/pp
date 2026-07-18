#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)
manifest="$script_dir/api-surface.allow"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    --manifest) manifest=$2; shift 2 ;;
    *) echo "usage: $0 [--root DIR] [--manifest FILE]" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

declarations() {
  awk '
    function emit(kind, name) {
      gsub(/[[:space:]]+/, " ", name)
      if (name ~ /^\(.*\)$/) gsub(/[[:space:]]/, "", name)
      print kind "|" name
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^module[[:space:]]+type[[:space:]]+/) {
        name = line
        sub(/^module[[:space:]]+type[[:space:]]+/, "", name)
        sub(/[[:space:]:=].*$/, "", name)
        emit("module-type", name)
      } else if (line ~ /^(val|type|exception|external|class|include|module)[[:space:]]+/) {
        kind = line
        sub(/[[:space:]].*$/, "", kind)
        name = line
        sub(/^[^[:space:]]+[[:space:]]+/, "", name)
        if (kind == "val" && name ~ /^\(/) {
          close_pos = index(name, ")")
          name = substr(name, 1, close_pos)
        } else sub(/[[:space:]:=].*$/, "", name)
        emit(kind, name)
      }
    }
  ' "$1"
}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

expected="$tmp/expected"
actual="$tmp/actual"
awk -F'|' '/^[[:space:]]*#/ || NF == 0 { next } NF != 3 { print "invalid API manifest row: " $0 > "/dev/stderr"; bad=1; next } { print $1 "|" $2 } END { if (bad) exit 1 }' "$manifest" | sort -u > "$expected"

for dir in src/kernel src/frontend; do
  while IFS= read -r file; do
    rel=${file#"$root"/}
    surface=$(declarations "$file" | sort)
    hash=$(printf '%s\n' "$surface" | digest)
    printf '%s|%s\n' "$rel" "$hash"
  done < <(find "$root/$dir" -maxdepth 1 -type f -name '*.mli' -print | sort)
done > "$actual"
sort -u "$actual" -o "$actual"

if ! diff -u "$expected" "$actual"; then
  echo "API surface drift: update the manifest only after reviewing the foundational interface change" >&2
  exit 1
fi
echo "API surface: foundational interfaces match the reviewed baseline"
