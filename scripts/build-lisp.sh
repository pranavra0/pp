#!/usr/bin/env bash
# Build the Common Lisp implementation as a saved, executable SBCL image.
# Ordinary invocations execute that image and never ask SBCL to compile source.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OUTPUT="$ROOT/lisp/pp"

usage() {
  cat >&2 <<'EOF'
usage: scripts/build-lisp.sh [--output PATH] [--print-toolchain-id]

Build a saved executable image.  SBCL is selected from $SBCL_BIN, then $SBCL,
then PATH (in that order); an unavailable explicit selection is an error.
--print-toolchain-id resolves and fingerprints the SBCL launcher, core,
runtime, and runtime shared-library inputs without building an image.
EOF
  exit 2
}

PRINT_TOOLCHAIN_ID=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || usage
      OUTPUT="$2"
      shift 2
      ;;
    --print-toolchain-id)
      PRINT_TOOLCHAIN_ID=1
      shift
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

sha256_file() {
  sha256sum -- "$1" | cut -d ' ' -f1
}

SBCL_VERSION=$("$SBCL_EXEC" --version 2>/dev/null | sed -n '1p')
SBCL_LAUNCHER_DIGEST=$(sha256_file "$SBCL_EXEC")
BUILD_SCRIPT_DIGEST=$(sha256_file "$ROOT/scripts/build-lisp.sh")
BUILD_DEFINITION_DIGEST=$(sha256_file "$ROOT/build/pp.pp")

# SBCL's launcher may be a script that selects a separate runtime and core.
# Ask the selected implementation for those exact paths rather than guessing
# a distro layout.  The runtime's ldd closure covers its loader and libraries.
SBCL_RUNTIME=$(
  "$SBCL_EXEC" --no-userinit --no-sysinit --non-interactive \
    --eval '(format t "PP-RUNTIME=~A~%" (namestring sb-ext:*runtime-pathname*))' --quit \
    2>&1 | sed -n 's/^PP-RUNTIME=//p'
)
SBCL_CORE=$(
  "$SBCL_EXEC" --no-userinit --no-sysinit --non-interactive \
    --eval '(format t "PP-CORE=~A~%" (namestring sb-ext:*core-pathname*))' --quit \
    2>&1 | sed -n 's/^PP-CORE=//p'
)
[ -f "$SBCL_RUNTIME" ] || {
  printf 'build-lisp.sh: SBCL runtime is unavailable: %s\n' "$SBCL_RUNTIME" >&2
  exit 1
}
[ -f "$SBCL_CORE" ] || {
  printf 'build-lisp.sh: SBCL core is unavailable: %s\n' "$SBCL_CORE" >&2
  exit 1
}
SBCL_RUNTIME_DIGEST=$(sha256_file "$SBCL_RUNTIME")
SBCL_CORE_DIGEST=$(sha256_file "$SBCL_CORE")
SBCL_SHARED_DEPENDENCIES=$(
  LC_ALL=C ldd "$SBCL_RUNTIME" 2>/dev/null || true
)
SBCL_SHARED_DEPENDENCY_PATHS=$(
  while IFS= read -r line; do
    case "$line" in
      *" => "*)
        dependency=${line#*=> }
        dependency=${dependency%% (*}
        ;;
      "/* ("*)
        dependency=${line%% (*}
        ;;
      *)
        continue
        ;;
    esac
    [ -f "$dependency" ] && readlink -f -- "$dependency"
  done <<< "$SBCL_SHARED_DEPENDENCIES" | LC_ALL=C sort -u
)
SBCL_SHARED_DEPENDENCIES_DIGEST=$(
  while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    printf '%s %s\n' "$dependency" "$(sha256_file "$dependency")"
  done <<< "$SBCL_SHARED_DEPENDENCY_PATHS" | sha256sum | cut -d ' ' -f1
)
SBCL_TOOLCHAIN_DIGEST=$(
  {
    printf 'sbcl-launcher-sha256=%s\n' "$SBCL_LAUNCHER_DIGEST"
    printf 'sbcl-runtime-sha256=%s\n' "$SBCL_RUNTIME_DIGEST"
    printf 'sbcl-core-sha256=%s\n' "$SBCL_CORE_DIGEST"
    printf 'sbcl-shared-dependencies-sha256=%s\n' "$SBCL_SHARED_DEPENDENCIES_DIGEST"
  } | sha256sum | cut -d ' ' -f1
)

if [ "$PRINT_TOOLCHAIN_ID" -eq 1 ]; then
  printf 'format=pp-sbcl-toolchain-v1\n'
  printf 'sbcl-version=%s\n' "$SBCL_VERSION"
  printf 'sbcl-launcher-sha256=%s\n' "$SBCL_LAUNCHER_DIGEST"
  printf 'sbcl-runtime-sha256=%s\n' "$SBCL_RUNTIME_DIGEST"
  printf 'sbcl-core-sha256=%s\n' "$SBCL_CORE_DIGEST"
  printf 'sbcl-shared-dependencies-sha256=%s\n' "$SBCL_SHARED_DEPENDENCIES_DIGEST"
  printf 'sbcl-toolchain-sha256=%s\n' "$SBCL_TOOLCHAIN_DIGEST"
  exit 0
fi

# Source and build-script inputs are kept separate from toolchain provenance.
# The source digest mirrors the source-only tree used by build/pp.pp.
# The saved executable bytes are not promised reproducible.
SOURCE_DIGEST=$(
  cd "$ROOT"
  {
    printf 'pp-source-tree-v2\n'
    {
      find lisp -type f \( -name '*.asd' -o -name '*.lisp' \) -print
      printf '%s\n' build/bootstrap.lisp build/pp.pp
    } | LC_ALL=C sort |
      while IFS= read -r path; do
        printf '%s  %s\n' "$(sha256_file "$path")" "$path"
      done
  } | sha256sum | cut -d ' ' -f1
)

BUILD_ID_FORMAT='pp-sbcl-image-v3'

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
  PP_TEMP_IMAGE="$TEMP_IMAGE" "$SBCL_EXEC" \
    --no-userinit --no-sysinit --non-interactive \
    --load build/bootstrap.lisp
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
#!/bin/bash
set -euo pipefail
SELF_DIR="\${BASH_SOURCE[0]%/*}"
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
  printf 'sbcl-launcher-sha256=%s\n' "$SBCL_LAUNCHER_DIGEST"
  printf 'sbcl-runtime-sha256=%s\n' "$SBCL_RUNTIME_DIGEST"
  printf 'sbcl-core-sha256=%s\n' "$SBCL_CORE_DIGEST"
  printf 'sbcl-shared-dependencies-sha256=%s\n' "$SBCL_SHARED_DEPENDENCIES_DIGEST"
  printf 'sbcl-toolchain-sha256=%s\n' "$SBCL_TOOLCHAIN_DIGEST"
  printf 'source-sha256=%s\n' "$SOURCE_DIGEST"
  printf 'build-script-sha256=%s\n' "$BUILD_SCRIPT_DIGEST"
  printf 'build-definition-sha256=%s\n' "$BUILD_DEFINITION_DIGEST"
} >"$TEMP_BUILD_ID"
mv -f "$TEMP_BUILD_ID" "$BUILD_ID_OUTPUT"
printf '%s\n' "$OUTPUT_ABS"
