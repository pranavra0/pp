#!/usr/bin/env bash
set -euo pipefail

root=$PWD
src_dir="$root/src"
allowlist="$root/scripts/state-inventory.allow"

usage() {
  echo "usage: $0 [--root DIR] [--src-dir DIR] [--allowlist FILE]" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    --src-dir) src_dir=$2; shift 2 ;;
    --allowlist) allowlist=$2; shift 2 ;;
    *) usage ;;
  esac
done

cd "$root"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

relpath() {
  local path=$1
  case "$path" in
    "$root"/*) printf '%s\n' "${path#"$root"/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

for file in "$src_dir"/*.ml "$src_dir"/*.mli; do
  [ -f "$file" ] || continue
  rel=$(relpath "$file")

  awk -v file="$rel" '
    function emit(kind, name) { print kind "|" file "|" name }
    /^[[:space:]]*mutable[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      line = $0
      sub(/^[[:space:]]*mutable[[:space:]]+/, "", line)
      sub(/[[:space:]].*$/, "", line)
      emit("mutable-field", line)
    }
    /^let[[:space:]]+[A-Za-z_][A-Za-z0-9_]*/ {
      line = $0
      sub(/^let[[:space:]]+(rec[[:space:]]+)?/, "", line)
      name = line
      sub(/[[:space:]:=].*$/, "", name)
      if (line ~ /=[[:space:]]*ref([[:space:]]|$)/)
        emit("top-ref", name)
      if (line ~ /Hashtbl\.create/)
        emit("top-table", name)
      if (in_decl && (decl ~ /=[[:space:]]*lazy[[:space:]]*\(/ || decl ~ /(^|\n)[[:space:]]*lazy[[:space:]]*\(/) && decl ~ /Sys\.getenv(_opt)?/)
        emit("lazy-env", decl_name)
      in_decl = 1
      decl_name = name
      decl = line "\n"
      next
    }
    in_decl {
      decl = decl $0 "\n"
    }
    END {
      if (in_decl && (decl ~ /=[[:space:]]*lazy[[:space:]]*\(/ || decl ~ /(^|\n)[[:space:]]*lazy[[:space:]]*\(/) && decl ~ /Sys\.getenv(_opt)?/)
        emit("lazy-env", decl_name)
    }
  ' "$file" >> "$tmp"

  while IFS=: read -r line text; do
    [ -n "$line" ] || continue
    signal=$(sed -n 's/.*Sys\.\(sig[A-Za-z0-9_]*\).*/\1/p' <<<"$text")
    [ -n "$signal" ] || signal="line-$line"
    printf 'signal-handler|%s|%s\n' "$rel" "$signal" >> "$tmp"
  done < <(grep -En 'Sys\.(set_)?signal[[:space:]]' "$file" || true)
done

sort -u "$tmp" -o "$tmp"
cat "$tmp"

[ -f "$allowlist" ] || {
  echo "state inventory allowlist not found: $allowlist" >&2
  exit 1
}

allowed=$(mktemp)
trap 'rm -f "$tmp" "$allowed"' EXIT
awk -F'|' '
  /^[[:space:]]*#/ || NF == 0 { next }
  NF != 4 || $4 == "" { print "invalid allowlist row: " $0 > "/dev/stderr"; bad = 1; next }
  { print $1 "|" $2 "|" $3 }
  END { if (bad) exit 1 }
' "$allowlist" | sort -u > "$allowed"

if ! diff -u "$allowed" "$tmp"; then
  echo "state inventory drift: add the declaration with its owner before changing source state" >&2
  exit 1
fi
