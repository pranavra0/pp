#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$script_dir/.." && pwd)

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root=$2; shift 2 ;;
    *) echo "usage: $0 [--root DIR]" >&2; exit 2 ;;
  esac
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

awk '/^and expr[[:space:]]*=/{inside=1; next} /^and value[[:space:]]*=/{inside=0} inside { while (match($0, /E[A-Z][A-Za-z0-9_]*/)) { print substr($0, RSTART, RLENGTH); $0=substr($0, RSTART+RLENGTH) } }' \
  "$root/src/kernel/core_model.mli" | sort -u > "$tmp/constructors"

code_contains() {
  local file=$1 token=$2
  awk -v token="$token" '
    function without_comments_and_strings(line, i, c, n, out) {
      out = ""
      in_string = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        n = substr(line, i + 1, 1)
        if (comment_depth > 0) {
          if (c == "(" && n == "*") { comment_depth++; i++ }
          else if (c == "*" && n == ")") { comment_depth--; i++ }
          continue
        }
        if (in_string) {
          if (c == "\\") i++
          else if (c == "\"") in_string = 0
          continue
        }
        if (c == "\"") { in_string = 1; continue }
        if (c == "(" && n == "*") { comment_depth = 1; i++; continue }
        out = out c
      }
      return out
    }
    BEGIN { pattern = "(^|[^A-Za-z0-9_])" token "([^A-Za-z0-9_]|$)" }
    { if (without_comments_and_strings($0) ~ pattern) found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file"
}

check() {
  local label=$1 file=$2 constructor=$3
  if ! code_contains "$file" "$constructor"; then
    echo "vertical slice: $constructor missing from $label ($file)" >&2
    return 1
  fi
}

status=0
while IFS= read -r constructor; do
  [ -n "$constructor" ] || continue
  for file in "$root/src/frontend/reader.ml" "$root/src/frontend/reader_braces.ml"; do
    check reader "$file" "$constructor" || status=1
  done
  for file in "$root/src/frontend/printer_sexpr.ml" "$root/src/frontend/printer_braces.ml"; do
    check printer "$file" "$constructor" || status=1
  done
  evaluator_found=0
  for evaluator_file in "$root/src/runtime"/evaluator*.ml; do
    if code_contains "$evaluator_file" "$constructor"; then
      evaluator_found=1
      break
    fi
  done
  if [ "$evaluator_found" -eq 0 ]; then
    echo "vertical slice: $constructor missing from evaluator dispatch" >&2
    status=1
  fi
  check hash "$root/src/kernel/identity.ml" "$constructor" || status=1
  check quote "$root/src/kernel/quotation.ml" "$constructor" || status=1
  check properties "$root/src/app/kernel_props.ml" "$constructor" || status=1
done < "$tmp/constructors"

for marker in 'expr_kind' 'gen_expr_of_tag' 'all_expr_tags' 'expr_surface'; do
  if ! grep -Eq "^[[:space:]]*(let|and)[[:space:]].*${marker}" "$root/src/app/kernel_props.ml"; then
    echo "vertical slice: kernel properties are missing the exhaustive $marker ratchet" >&2
    status=1
  fi
done

if ! code_contains "$root/tools/fuzz.ml" 'Kernel_props[.]run'; then
  echo "vertical slice: fuzzer does not invoke the exhaustive kernel properties" >&2
  status=1
fi

if [ "$status" -ne 0 ]; then exit "$status"; fi
echo "Vertical slices: readers, evaluator, printers, identity, quotation, properties, and fuzzer are connected"
