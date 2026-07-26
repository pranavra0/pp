#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MANUAL="$ROOT/docs/manual"
PP=${PP:-"$ROOT/bin/pp"}
CAPTURED="$MANUAL/captured"
SITE="$MANUAL/site"

mkdir -p "$CAPTURED" "$SITE"

mapfile -t examples < <(
  awk '
    {
      line = $0
      while (match(line, /#example\("[^"]+"/)) {
        example = substr(line, RSTART, RLENGTH)
        sub(/^#example\("/, "", example)
        sub(/"$/, "", example)
        print example
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$MANUAL/chapters"/*.typ \
    "$MANUAL/website.typ" "$MANUAL/paths.typ" "$MANUAL/models.typ" \
    "$MANUAL/gallery.typ" "$MANUAL/before-after.typ" \
    "$MANUAL/observability.typ" "$MANUAL/constraints.typ" \
    | sort -u
)

for name in "${examples[@]}"; do
  if [ -f "$MANUAL/examples/$name.sh" ]; then
    (
      cd "$ROOT"
      PP="$PP" bash "$MANUAL/examples/$name.sh"
    ) >"$CAPTURED/$name.out" 2>&1
  else
    printf 'pp %s.pp\n' "$name" >"$CAPTURED/$name.cmd"
    status=0
    (
      cd "$MANUAL/examples"
      example_home=$(mktemp -d)
      example_status=0
      HOME="$example_home" "$PP" "$name.pp" || example_status=$?
      rm -rf "$example_home"
      exit "$example_status"
    ) >"$CAPTURED/$name.out" 2>&1 || status=$?
    case "$name" in
      cap-read|type-error|ref-type-error)
        [ "$status" -ne 0 ] || {
          echo "manual error example unexpectedly succeeded: $name" >&2
          exit 1
        }
        ;;
      *)
        [ "$status" -eq 0 ] || {
          echo "manual example failed: $name" >&2
          cat "$CAPTURED/$name.out" >&2
          exit "$status"
        }
        ;;
    esac
  fi
done

(
  cd "$MANUAL"
  typst compile --root . manual.typ site/pp-manual.pdf
  typst compile --root . --features html --format html manual.typ site/manual.html
  typst compile --root . --features html --format html website.typ site/index.html
  typst compile --root . --features html --format html chapters/11-cookbook.typ site/cookbook.html
  typst compile --root . --features html --format html paths.typ site/paths.html
  typst compile --root . --features html --format html models.typ site/models.html
  typst compile --root . --features html --format html gallery.typ site/gallery.html
  typst compile --root . --features html --format html before-after.typ site/before-after.html
  typst compile --root . --features html --format html observability.typ site/observability.html
  typst compile --root . --features html --format html constraints.typ site/constraints.html
)
