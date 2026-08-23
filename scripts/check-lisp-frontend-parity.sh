#!/usr/bin/env bash
# Cross-engine frontend verification.  Every command reads the same checked-in
# source fixture; no expected printer output is used as an oracle.  The OCaml
# process is the reference implementation and the Lisp process is the
# candidate, both selected explicitly by the caller.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FIXTURES="$ROOT/lisp/tests/frontend/parity"
OCAML=""
LISP=""

usage() {
  cat >&2 <<'EOF'
usage: scripts/check-lisp-frontend-parity.sh --ocaml PATH --lisp PATH

Both executable paths are required.  The checker runs the shared frontend
fixtures through conversion, brace emission/roundtrip, hash comparison,
comment scanning, lint, surface-table dumping, and malformed-input paths.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml)
      [ "$#" -ge 2 ] || { echo 'frontend parity: --ocaml requires a path' >&2; exit 2; }
      OCAML=$2; shift 2 ;;
    --lisp)
      [ "$#" -ge 2 ] || { echo 'frontend parity: --lisp requires a path' >&2; exit 2; }
      LISP=$2; shift 2 ;;
    -h|--help)
      usage >&2; exit 0 ;;
    *)
      echo "frontend parity: unrecognized argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[ -n "$OCAML" ] && [ -n "$LISP" ] || { usage; exit 2; }
[ -x "$OCAML" ] || { printf 'frontend parity: OCaml executable is not executable: %s\n' "$OCAML" >&2; exit 2; }
[ -x "$LISP" ] || { printf 'frontend parity: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
[ -d "$FIXTURES" ] || { printf 'frontend parity: fixture directory is missing: %s\n' "$FIXTURES" >&2; exit 2; }

SEXPR="$FIXTURES/sexpr-composite.ppl"
ROUNDTRIP="$FIXTURES/sexpr-roundtrip.ppl"
BRACE="$FIXTURES/brace-composite.pp"
EQUIVALENT="$FIXTURES/brace-equivalent.pp"
DIFFERENT="$FIXTURES/brace-different.pp"
UNPRINTABLE="$FIXTURES/sexpr-unprintable.ppl"
BAD_SEXPR="$FIXTURES/malformed-sexpr.ppl"
BAD_BRACE="$FIXTURES/malformed-brace.pp"
for fixture in "$SEXPR" "$ROUNDTRIP" "$BRACE" "$EQUIVALENT" "$DIFFERENT" "$UNPRINTABLE" "$BAD_SEXPR" "$BAD_BRACE"; do
  [ -r "$fixture" ] || { printf 'frontend parity: fixture is not readable: %s\n' "$fixture" >&2; exit 2; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-frontend-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Only run-specific path prefixes are normalized.  Diagnostic text and line /
# column ranges remain byte-for-byte evidence of the two frontend readers.
normalize_stderr() {
  local input=$1 output=$2 text
  text=$(cat "$input")
  text=${text//"$FIXTURES"/<fixtures>}
  text=${text//"$ROOT"/<repo>}
  printf '%s' "$text" >"$output"
}

run_pair() {
  local label=$1 expected=$2
  shift 2
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local ocaml_status lisp_status failed=0

  set +e
  "$OCAML" "$@" >"$ocaml_out" 2>"$ocaml_err"
  ocaml_status=$?
  "$LISP" "$@" >"$lisp_out" 2>"$lisp_err"
  lisp_status=$?
  set -e
  normalize_stderr "$ocaml_err" "$ocaml_norm"
  normalize_stderr "$lisp_err" "$lisp_norm"

  printf 'CHECK %s\n' "$label"
  if [ "$ocaml_status" -eq "$lisp_status" ]; then
    printf '  exit status: match (%s)\n' "$ocaml_status"
  else
    printf '  exit status: DIFFER (ocaml=%s lisp=%s)\n' "$ocaml_status" "$lisp_status"
    failed=1
  fi
  if [ "$ocaml_status" -eq "$expected" ] && [ "$lisp_status" -eq "$expected" ]; then
    printf '  expected status: %s\n' "$expected"
  else
    printf '  expected status: DIFFER (required=%s)\n' "$expected"
    failed=1
  fi
  if cmp -s "$ocaml_out" "$lisp_out"; then
    printf '  stdout: match\n'
  else
    printf '  stdout: DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_out" "$lisp_out" || true
    failed=1
  fi
  if cmp -s "$ocaml_norm" "$lisp_norm"; then
    printf '  stderr (normalized diagnostics/ranges): match\n'
  else
    printf '  stderr (normalized diagnostics/ranges): DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_norm" "$lisp_norm" || true
    failed=1
  fi
  if [ "$failed" -ne 0 ]; then
    # This wording makes an old reference that predates a frontend command
    # distinguishable from an ordinary semantic or printer mismatch.
    local diagnostic
    diagnostic=$(cat "$ocaml_err" "$lisp_err")
    case "$diagnostic" in
      *'unrecognized option'*|*'unknown option'*|*'unsupported option'*)
        printf '  limitation: one executable appears stale and lacks this frontend command\n' ;;
    esac
    printf '  result: FAIL\n'
  else
    printf '  result: PASS\n'
  fi
  return "$failed"
}

failures=0
# Both conversion directions carry comments and exercise composite, quoted,
# observation, and brace forms.  No checked-in output is treated as golden.
run_pair 'fmt-sexpr-to-braces' 0 fmt --to-braces "$SEXPR" || failures=$((failures + 1))
run_pair 'fmt-braces-to-sexpr' 0 fmt --to-sexpr "$BRACE" || failures=$((failures + 1))
run_pair 'emit-braces' 0 --emit-braces "$SEXPR" || failures=$((failures + 1))
run_pair 'roundtrip-braces' 0 --roundtrip-braces "$ROUNDTRIP" || failures=$((failures + 1))

# --compare-hash has no stdout on success: its exit status is the AST/hash
# result.  Exercise both equal and intentionally unequal ASTs.
run_pair 'compare-hash-equal' 0 --compare-hash "$BRACE" "$EQUIVALENT" || failures=$((failures + 1))
run_pair 'compare-hash-different' 1 --compare-hash "$BRACE" "$DIFFERENT" || failures=$((failures + 1))

run_pair 'list-comments-sexpr' 0 --list-comments sexpr "$SEXPR" || failures=$((failures + 1))
run_pair 'list-comments-brace' 0 --list-comments brace "$BRACE" || failures=$((failures + 1))
run_pair 'lint-brace' 0 lint "$BRACE" || failures=$((failures + 1))
run_pair 'dump-surface-tables' 0 --dump-surface-tables || failures=$((failures + 1))

# Typed parameters currently have no brace printer spelling.  This is a
# required unsupported-printer boundary, not a self-golden success case.
run_pair 'unsupported-emit-braces' 1 --emit-braces "$UNPRINTABLE" || failures=$((failures + 1))
run_pair 'unsupported-fmt-to-braces' 1 fmt --to-braces "$UNPRINTABLE" || failures=$((failures + 1))
run_pair 'unsupported-roundtrip' 1 --roundtrip-braces "$UNPRINTABLE" || failures=$((failures + 1))

# Malformed sexpr and brace input must fail with matching normalized source
# ranges; wording is intentionally not relaxed.
run_pair 'malformed-sexpr' 1 fmt --to-braces "$BAD_SEXPR" || failures=$((failures + 1))
run_pair 'malformed-brace' 1 fmt --to-sexpr "$BAD_BRACE" || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  printf 'frontend parity: FAIL (%s checks)\n' "$failures" >&2
  printf 'frontend parity: mismatches are against the selected OCaml reference; stale/toolchain limitations are reported per check.\n' >&2
  exit 1
fi
printf 'frontend parity: OK (shared fixtures, conversions, AST/hash status, diagnostics, comments, lint, tables)\n'
exit 0
