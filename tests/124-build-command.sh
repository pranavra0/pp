#!/usr/bin/env bash
# The initial self-build command runs through run-closed! and emits provenance.
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
PP=${PP:-"$ROOT/bin/pp"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-build-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# The build definition snapshots the selected external SBCL as a content-
# addressed toolchain.  Grant only the runtime and SBCL_HOME read roots.
SBCL_RUNTIME=$(sbcl --no-userinit --no-sysinit --non-interactive \
  --eval '(format t "PP-RUNTIME=~A~%" (namestring sb-ext:*runtime-pathname*))' \
  --quit 2>&1 | sed -n 's/^PP-RUNTIME=//p')
SBCL_HOME=$(sbcl --no-userinit --no-sysinit --non-interactive \
  --eval '(format t "PP-HOME=~A~%" (namestring (make-pathname :name nil :type nil :defaults sb-ext:*core-pathname*)))' \
  --quit 2>&1 | sed -n 's/^PP-HOME=//p')
[ -n "$SBCL_RUNTIME" ] && [ -n "$SBCL_HOME" ]

# Keep the build command's cwd isolated while reusing the already-built image.
cp -a "$ROOT/lisp" "$ROOT/scripts" "$ROOT/build" "$ROOT/bin" "$TMP/"
# Preserve the copied executable and SBCL image: bin/pp uses them to run the fixture.

BUILD_GRANTS=(
  --grant process
  --grant "fs:$TMP:rw"
  --grant "fs:$SBCL_RUNTIME:ro"
  --grant "fs:$SBCL_HOME:ro"
)

output=$(cd "$TMP" && "$TMP/bin/pp" build pp "${BUILD_GRANTS[@]}")
printf '%s\n' "$output"
case "$output" in
  *"provider=scripting-only"*"provenance=build/pp.sbcl-image.build-id"*) ;;
  *) printf 'self-build: missing provenance diagnostic\n' >&2; exit 1 ;;
esac
[ -x "$TMP/build/pp" ]
[ -x "$TMP/build/pp.sbcl-image" ]
[ -s "$TMP/build/pp.sbcl-image.build-id" ]
grep -q '^format=pp-sbcl-image-v4$' "$TMP/build/pp.sbcl-image.build-id"
grep -q '^toolchain-tree-sha256=' "$TMP/build/pp.sbcl-image.build-id"
grep -q '^loader-closure=ambient$' "$TMP/build/pp.sbcl-image.build-id"
if grep -q 'build-lisp.sh' "$TMP/build/pp.pp"; then
  printf 'self-build: canonical request retained the shell build wrapper\n' >&2
  exit 1
fi
[ "$(cd "$TMP" && "$TMP/build/pp" --version)" = 'pp v0.2.0-dev' ]

source_before=$(sed -n 's/^source-sha256=//p' "$TMP/build/pp.sbcl-image.build-id")
definition_before=$(sed -n 's/^build-definition-sha256=//p' "$TMP/build/pp.sbcl-image.build-id")
mkdir -p "$TMP/lisp/runtime/generated"
touch "$TMP/lisp/pp"
printf 'generated fasl\n' > "$TMP/lisp/runtime/generated/ignored.fasl"
printf 'ignored readme\n' > "$TMP/lisp/README"
printf 'ignored readme\n' > "$TMP/README.md"

repro_output=$(cd "$TMP" && "$TMP/bin/pp" build pp --repro-check \
  "${BUILD_GRANTS[@]}")
printf '%s\n' "$repro_output"
case "$repro_output" in
  *"cache=empty"*"request-sha256="*"byte-compare=DIFFERENT; differing-files=build/pp.sbcl-image(bytes differ)"*) ;;
  *) printf 'self-build: repro-check did not report byte differences\n' >&2; exit 1 ;;
esac
source_after=$(sed -n 's/^source-sha256=//p' "$TMP/build/pp.sbcl-image.build-id")
definition_after=$(sed -n 's/^build-definition-sha256=//p' "$TMP/build/pp.sbcl-image.build-id")
[ "$source_before" = "$source_after" ]
[ "$definition_before" = "$definition_after" ]
[ "$(cd "$TMP" && "$TMP/build/pp" --version)" = 'pp v0.2.0-dev' ]
printf '%s\n' 'ok   build-command'
