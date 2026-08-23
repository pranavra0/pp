#!/usr/bin/env bash
# Build the Common Lisp implementation as a saved, executable SBCL image.
# Ordinary invocations execute that image and never ask SBCL to compile source.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUTPUT="$ROOT/lisp/pp"

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-lisp.sh [--output PATH]

Build a saved executable image.  SBCL is selected from $SBCL_BIN, then $SBCL,
then PATH (in that order); an unavailable explicit selection is an error.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    *)
      printf 'build-lisp.sh: unknown argument: %s\n' "$1" >&2
      usage
      ;;
  esac
done

# Resolve the executable without falling back after an explicit override.
SBCL_REQUESTED="${SBCL_BIN:-${SBCL:-sbcl}}"
if [[ "$SBCL_REQUESTED" == */* ]]; then
  [ -x "$SBCL_REQUESTED" ] || {
    printf 'build-lisp.sh: SBCL is not executable: %s\n' "$SBCL_REQUESTED" >&2
    exit 127
  }
  case "$SBCL_REQUESTED" in
    /*) SBCL_EXEC="$SBCL_REQUESTED" ;;
    *) SBCL_EXEC="$(cd -P "$(dirname "$SBCL_REQUESTED")" && pwd)/$(basename "$SBCL_REQUESTED")" ;;
  esac
else
  SBCL_EXEC=$(command -v "$SBCL_REQUESTED" 2>/dev/null || true)
  [ -n "$SBCL_EXEC" ] || {
    printf 'build-lisp.sh: SBCL not found (requested %s)\n' "$SBCL_REQUESTED" >&2
    exit 127
  }
fi

SBCL_VERSION=$("$SBCL_EXEC" --version 2>/dev/null | sed -n '1p')
SBCL_DIGEST=$(sha256sum -- "$SBCL_EXEC" | cut -d ' ' -f1)
BUILD_SCRIPT_DIGEST=$(sha256sum -- "$ROOT/scripts/build-lisp.sh" | cut -d ' ' -f1)

# SBCL executable/core bytes can contain runtime-specific data even when the
# source and toolchain are unchanged.  Record a stable identity for the exact
# inputs instead of claiming byte-for-byte reproducibility.
SOURCE_DIGEST=$(
  cd "$ROOT"
  {
    printf 'pp-lisp-source-v1\n'
    find lisp -type f \( -name '*.asd' -o -name '*.lisp' \) -print0 |
      LC_ALL=C sort -z |
      xargs -0 --no-run-if-empty sha256sum
  } | sha256sum | cut -d ' ' -f1
)

BUILD_ID_FORMAT='pp-sbcl-image-v1'

# Resolve a relative output against the caller's directory, not ROOT.  This
# makes --output build/pp behave like ordinary command-line tools.
case "$OUTPUT" in
  /*) OUTPUT_ABS="$OUTPUT" ;;
  *) OUTPUT_ABS="$(pwd -P)/$OUTPUT" ;;
esac
OUTPUT_DIR=$(dirname "$OUTPUT_ABS")
mkdir -p "$OUTPUT_DIR"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/pp-lisp-build.XXXXXX")
TEMP_IMAGE="$TEMP_DIR/pp"
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT HUP INT TERM

# SBCL itself reserves runtime-looking options unless the saved image opts out
# of normal runtime option processing.  SAVE-RUNTIME-OPTIONS makes every
# argument (including --help and malformed --version) reach pp.app:main.
# Keep the actual saved ELF image beside a tiny launcher so pp owns those
# documented spellings without giving up the no-runtime-compilation property.
IMAGE_OUTPUT="${OUTPUT_ABS}.sbcl-image"
# Loading the ASDF system is a build-time operation.  The saved image has
# pp.app:main as its toplevel and contains all loaded source/compiled code.
if ! (
  cd "$ROOT"
  PP_LISP_TEMP_IMAGE="$TEMP_IMAGE" "$SBCL_EXEC" \
    --no-userinit --no-sysinit --non-interactive \
    --eval '(require :asdf)' \
    --eval '(asdf:load-asd (truename "lisp/pp.asd"))' \
    --eval '(asdf:load-system "pp")' \
    --eval "(sb-ext:save-lisp-and-die (sb-ext:posix-getenv \"PP_LISP_TEMP_IMAGE\") :toplevel #'pp.app:main :executable t :save-runtime-options t :purify t :compression 9)"
) >"$TEMP_DIR/sbcl.stdout" 2>"$TEMP_DIR/sbcl.stderr"; then
  cat "$TEMP_DIR/sbcl.stdout" "$TEMP_DIR/sbcl.stderr" >&2
  exit 1
fi

[ -f "$TEMP_IMAGE" ] || {
  printf 'build-lisp.sh: SBCL did not produce an image: %s\n' "$TEMP_IMAGE" >&2
  exit 1
}
chmod 0755 "$TEMP_IMAGE"
mv -f "$TEMP_IMAGE" "$IMAGE_OUTPUT"

IMAGE_BASENAME=$(basename "$IMAGE_OUTPUT")
cat > "$OUTPUT_ABS" <<EOF
#!/usr/bin/env bash
set -euo pipefail
SELF="\${BASH_SOURCE[0]}"
while [ -L "\$SELF" ]; do
  SELF_DIR="\$(cd -P -- "\$(dirname -- "\$SELF")" && pwd)"
  SELF_LINK="\$(readlink -- "\$SELF")"
  case "\$SELF_LINK" in
    /*) SELF="\$SELF_LINK" ;;
    *) SELF="\$SELF_DIR/\$SELF_LINK" ;;
  esac
done
SELF_DIR="\$(cd -P -- "\$(dirname -- "\$SELF")" && pwd)"
exec "\$SELF_DIR/$IMAGE_BASENAME" "\$@"
EOF
chmod 0755 "$OUTPUT_ABS"

# This identity is stable for unchanged source/tool inputs.  It deliberately
# does not claim that SBCL's saved executable bytes are reproducible.
BUILD_ID_OUTPUT="${IMAGE_OUTPUT}.build-id"
TEMP_BUILD_ID="$TEMP_DIR/build-id"
{
  printf 'format=%s\n' "$BUILD_ID_FORMAT"
  printf 'sbcl-version=%s\n' "$SBCL_VERSION"
  printf 'sbcl-sha256=%s\n' "$SBCL_DIGEST"
  printf 'source-sha256=%s\n' "$SOURCE_DIGEST"
  printf 'build-script-sha256=%s\n' "$BUILD_SCRIPT_DIGEST"
} >"$TEMP_BUILD_ID"
mv -f "$TEMP_BUILD_ID" "$BUILD_ID_OUTPUT"
printf '%s\n' "$OUTPUT_ABS"
