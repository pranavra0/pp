#!/usr/bin/env bash
# Compare the OCaml reference and Lisp candidate on one shared kernel corpus.
# The fixture flag is a developer/parity seam; production command behavior is
# not inferred from these rows and no checked-in output is treated as authority.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
CORPUS="$ROOT/lisp/tests/kernel-parity/corpus.tsv"

usage() {
  printf '%s\n' "Usage: $0 --ocaml PATH --lisp PATH"
  printf '%s\n' "Both executable paths are required; no binary is selected implicitly."
}
OCAML=""
LISP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OCAML=$2; shift 2 ;;
    --lisp) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; LISP=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[ -n "$OCAML" ] && [ -n "$LISP" ] || { usage >&2; exit 2; }
[ -x "$OCAML" ] || { printf 'parity: OCaml executable is not executable: %s\n' "$OCAML" >&2; exit 2; }
[ -x "$LISP" ] || { printf 'parity: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
[ -r "$CORPUS" ] || { printf 'parity: corpus is not readable: %s\n' "$CORPUS" >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-kernel-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Each process opens and parses the same path.  Neither side receives a static
# expected output or generated OCaml values from the other process.
"$OCAML" --kernel-fixture "$CORPUS" >"$TMP/ocaml.out" 2>"$TMP/ocaml.err"
"$LISP" --kernel-fixture-corpus "$CORPUS" >"$TMP/lisp.out" 2>"$TMP/lisp.err"
if ! cmp -s "$TMP/ocaml.out" "$TMP/lisp.out"; then
  printf '%s\n' 'parity: shared-corpus protocol differs between engines' >&2
  diff -u "$TMP/ocaml.out" "$TMP/lisp.out" >&2 || true
  exit 1
fi

# Every record is category, row-name, canonical-output, digest.  Validate the
# framing independently so a malformed line cannot be hidden by a coincidental
# textual comparison.
if awk -F '\t' 'NF != 4 { bad = 1 } END { exit bad ? 0 : 1 }' "$TMP/ocaml.out"; then
  printf '%s\n' 'parity: output record does not have four tab-delimited fields' >&2
  exit 1
fi
for category in expr value pattern capability cell identity codec; do
  corpus_count=$(awk -F '\t' -v wanted="$category" '$1 == wanted { n++ } END { print n + 0 }' "$CORPUS")
  output_count=$(awk -F '\t' -v wanted="$category" '$1 == wanted { n++ } END { print n + 0 }' "$TMP/ocaml.out")
  [ "$corpus_count" = "$output_count" ] || {
    printf 'parity: %s row count mismatch (%s != %s)\n' "$category" "$output_count" "$corpus_count" >&2
    exit 1
  }
done

# Capability rows carry the algebra ratchet in their canonical output.  The
# corpus includes none, all atomic kinds, composition, and restriction; all
# three checks are expected to hold for this corpus.
if awk -F '\t' '$1 == "capability" && $3 !~ /\|subset=true\|compose=true\|restrict=true$/ { bad = 1 }
                END { exit bad ? 0 : 1 }' "$TMP/ocaml.out"; then
  printf '%s\n' 'parity: capability algebra result is not sound' >&2
  exit 1
fi

# Exact arity is part of the seam.  Append a trailing field and require both
# explicit engines to reject it; this also exercises empty SPEC rows safely.
awk '/^[^#[:space:]]/ { print $0 "\ttrailing"; exit }' "$CORPUS" >"$TMP/trailing.tsv"
if "$OCAML" --kernel-fixture "$TMP/trailing.tsv" >"$TMP/trailing.ocaml.out" 2>"$TMP/trailing.ocaml.err"; then
  printf '%s\n' 'parity: OCaml accepted a trailing fixture field' >&2
  exit 1
fi
if "$LISP" --kernel-fixture-corpus "$TMP/trailing.tsv" >"$TMP/trailing.lisp.out" 2>"$TMP/trailing.lisp.err"; then
  printf '%s\n' 'parity: Lisp accepted a trailing fixture field' >&2
  exit 1
fi
printf 'unknown\tbad\tbad\tbad\n' >"$TMP/unknown.tsv"
if "$OCAML" --kernel-fixture "$TMP/unknown.tsv" >"$TMP/unknown.ocaml.out" 2>"$TMP/unknown.ocaml.err"; then
  printf '%s\n' 'parity: OCaml accepted an unknown fixture category' >&2
  exit 1
fi
if "$LISP" --kernel-fixture-corpus "$TMP/unknown.tsv" >"$TMP/unknown.lisp.out" 2>"$TMP/unknown.lisp.err"; then
  printf '%s\n' 'parity: Lisp accepted an unknown fixture category' >&2
  exit 1
fi

# An empty existing file is not a corpus.  In particular, an operation token
# that happens to name an existing file must remain operation mode and fail
# for missing arguments rather than silently producing no output.
: >"$TMP/empty.tsv"
if "$LISP" --kernel-fixture-corpus "$TMP/empty.tsv" >"$TMP/empty.out" 2>"$TMP/empty.err"; then
  printf '%s\n' 'parity: Lisp accepted an empty corpus path' >&2
  exit 1
fi
mkdir "$TMP/op-cwd"
: >"$TMP/op-cwd/hash-string"
if (cd "$TMP/op-cwd" && "$LISP" --kernel-fixture hash-string >"$TMP/op.out" 2>"$TMP/op.err"); then
  printf '%s\n' 'parity: Lisp treated an operation token as an empty corpus' >&2
  exit 1
fi

# Constructor specs are data fields, never host-language objects/read syntax.
printf 'expr\tbad\tliteral-int\t(+ 1 2)\n' >"$TMP/host-object.tsv"
if "$LISP" --kernel-fixture-corpus "$TMP/host-object.tsv" >"$TMP/host.out" 2>"$TMP/host.err"; then
  printf '%s\n' 'parity: Lisp accepted host-reader fixture syntax' >&2
  exit 1
fi

# Reserved help mode rejects positional arguments at pp's own boundary.
if "$LISP" --help extra >"$TMP/help.out" 2>"$TMP/help.err"; then
  help_status=0
else
  help_status=$?
fi
[ "$help_status" -eq 1 ] || {
  printf 'parity: Lisp --help extra returned status %s (want 1)\n' "$help_status" >&2
  exit 1
}

printf '%s\n' 'kernel-parity: OK (shared corpus, canonical records, capability algebra, strict framing)'

