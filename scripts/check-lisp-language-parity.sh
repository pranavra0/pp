#!/usr/bin/env bash
# Cross-engine pure-language verification. The selected OCaml executable is the
# reference and the selected Lisp executable is the candidate; both consume the
# same checked-in source/stdin fixtures. This checker has no expected-value
# oracle: stdout and diagnostics are compared only between the two processes.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FIXTURES="$ROOT/lisp/tests/language/parity"
OCAML=""
LISP=""
TIMEOUT_SECONDS=15

usage() {
  cat >&2 <<'EOF'
usage: scripts/check-lisp-language-parity.sh --ocaml PATH --lisp PATH

Both executable paths are required.  The checker runs the shared pure .pp/.ppl
corpus through both engines and compares exit status, stdout, and normalized
stderr (including source ranges).  It also compares a multiline brace REPL
input.  Effect, node, and distribution fixtures are reported as explicit
boundaries and are never counted as pure-language passes.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml)
      [ "$#" -ge 2 ] || { echo 'language parity: --ocaml requires a path' >&2; exit 2; }
      OCAML=$2; shift 2 ;;
    --lisp)
      [ "$#" -ge 2 ] || { echo 'language parity: --lisp requires a path' >&2; exit 2; }
      LISP=$2; shift 2 ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || { echo 'language parity: --timeout-seconds requires a value' >&2; exit 2; }
      TIMEOUT_SECONDS=$2; shift 2 ;;
    -h|--help)
      usage >&2; exit 0 ;;
    *)
      echo "language parity: unrecognized argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[ -n "$OCAML" ] && [ -n "$LISP" ] || { usage; exit 2; }
[ -x "$OCAML" ] || { printf 'language parity: OCaml executable is not executable: %s\n' "$OCAML" >&2; exit 2; }
[ -x "$LISP" ] || { printf 'language parity: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
[ -d "$FIXTURES" ] || { printf 'language parity: fixture directory is missing: %s\n' "$FIXTURES" >&2; exit 2; }
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) printf 'language parity: timeout must be an integer: %s\n' "$TIMEOUT_SECONDS" >&2; exit 2 ;;
esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || { echo 'language parity: timeout must be positive' >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-language-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/home-ocaml" "$TMP/home-lisp"

# Normalize only process-specific paths and line endings.  Source file names,
# line/column ranges, error tags, and all other diagnostic text remain evidence
# from the engines and therefore are not relaxed.
normalize_stderr() {
  local input=$1 output=$2
  sed \
    -e "s|$FIXTURES|<fixtures>|g" \
    -e "s|$ROOT|<repo>|g" \
    -e "s|$TMP|<tmp>|g" \
    -e 's/\r$//' \
    -e 's|<repl>|<stdin>|g' \
    "$input" >"$output"
}

run_process() {
  local engine=$1 home=$2 output=$3 error=$4
  shift 4
  (cd "$ROOT" && HOME="$home" timeout --signal=TERM "${TIMEOUT_SECONDS}s" "$engine" "$@") \
    >"$output" 2>"$error"
}

run_pair() {
  local label=$1 expected=$2 fixture=$3
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local ocaml_status lisp_status failed=0

  set +e
  run_process "$OCAML" "$TMP/home-ocaml" "$ocaml_out" "$ocaml_err" "$fixture"
  ocaml_status=$?
  run_process "$LISP" "$TMP/home-lisp" "$lisp_out" "$lisp_err" "$fixture"
  lisp_status=$?
  set +e
  normalize_stderr "$ocaml_err" "$ocaml_norm"
  normalize_stderr "$lisp_err" "$lisp_norm"

  printf 'CHECK %s (%s)\n' "$label" "$(basename "$fixture")"
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
  # A successful corpus program must produce an observable value, and an
  # expected error must produce diagnostics.  This qualitative guard keeps a
  # no-op/self-golden stub from passing while avoiding any expected-output
  # oracle.
  if [ "$expected" -eq 0 ] && [ ! -s "$ocaml_out" ]; then
    printf '  reference stdout: unexpectedly empty\n'
    failed=1
  elif [ "$expected" -ne 0 ] && [ ! -s "$ocaml_norm" ]; then
    printf '  reference stderr: unexpectedly empty\n'
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
    printf '  result: FAIL\n'
  else
    printf '  result: PASS\n'
  fi
  return "$failed"
}

run_stdin_pair() {
  local label=$1 expected=$2 input=$3
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local ocaml_status lisp_status failed=0

  set +e
  (cd "$ROOT" && HOME="$TMP/home-ocaml" timeout --signal=TERM "${TIMEOUT_SECONDS}s" "$OCAML" <"$input") \
    >"$ocaml_out" 2>"$ocaml_err"
  ocaml_status=$?
  (cd "$ROOT" && HOME="$TMP/home-lisp" timeout --signal=TERM "${TIMEOUT_SECONDS}s" "$LISP" <"$input") \
    >"$lisp_out" 2>"$lisp_err"
  lisp_status=$?
  set +e
  normalize_stderr "$ocaml_err" "$ocaml_norm"
  normalize_stderr "$lisp_err" "$lisp_norm"

  printf 'CHECK %s (%s)\n' "$label" "$(basename "$input")"
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
  # The multiline fixture has observable REPL values; keep a no-op candidate
  # from passing without introducing a checked-in expected-output oracle.
  if [ "$expected" -eq 0 ] && [ ! -s "$ocaml_out" ]; then
    printf '  reference stdout: unexpectedly empty\n'
    failed=1
  elif [ "$expected" -ne 0 ] && [ ! -s "$ocaml_norm" ]; then
    printf '  reference stderr: unexpectedly empty\n'
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
    printf '  result: FAIL\n'
  else
    printf '  result: PASS\n'
  fi
  return "$failed"
}

run_boundary() {
  local label=$1 category=$2 fixture=$3
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_status lisp_status

  set +e
  run_process "$OCAML" "$TMP/home-ocaml" "$ocaml_out" "$ocaml_err" "$fixture"
  ocaml_status=$?
  run_process "$LISP" "$TMP/home-lisp" "$lisp_out" "$lisp_err" "$fixture"
  lisp_status=$?
  set +e

  printf 'BOUNDARY %s: %s (%s)\n' "$label" "$category" "$(basename "$fixture")"
  printf '  pure-language parity is not claimed for this boundary input.\n'
  printf '  observed exit status: ocaml=%s lisp=%s\n' "$ocaml_status" "$lisp_status"

  # Boundary processes may accept or cleanly reject; abnormal statuses fail.
  if [ "$ocaml_status" -ne 0 ] && [ "$ocaml_status" -ne 1 ]; then
    printf '  result: FAIL (reference abnormal status %s)\n' "$ocaml_status"
    return 1
  fi
  if [ "$lisp_status" -ne 0 ] && [ "$lisp_status" -ne 1 ]; then
    printf '  result: FAIL (candidate abnormal status %s)\n' "$lisp_status"
    return 1
  fi
  if [ "$lisp_status" -eq 0 ]; then
    printf '  result: BOUNDARY (candidate accepted; no pure-language comparison)\n'
  elif [ "$ocaml_status" -eq 0 ]; then
    printf '  result: BOUNDARY (candidate cleanly rejected; reference accepted)\n'
  else
    printf '  result: BOUNDARY (both engines cleanly rejected; no pure-language comparison)\n'
  fi
  return 0
}

# Explicit list prevents a boundary fixture from being accidentally treated as
# a pure success case and keeps the corpus small and reviewable.
PURE_FIXTURES=(
  "$FIXTURES/core.pp"
  "$FIXTURES/core.ppl"
  "$FIXTURES/definitions.pp"
  "$FIXTURES/definitions.ppl"
  "$FIXTURES/patterns.pp"
  "$FIXTURES/patterns.ppl"
  "$FIXTURES/type-error.pp"
  "$FIXTURES/type-error.ppl"
  "$FIXTURES/runtime-error.pp"
  "$FIXTURES/runtime-error.ppl"
)
for fixture in "${PURE_FIXTURES[@]}"; do
  [ -r "$fixture" ] || { printf 'language parity: fixture is not readable: %s\n' "$fixture" >&2; exit 2; }
done
REPL_INPUT="$FIXTURES/repl.stdin"
BOUNDARY_FIXTURES=(
  "$FIXTURES/boundary-effects.pp"
  "$FIXTURES/boundary-effects.ppl"
  "$FIXTURES/boundary-node.pp"
  "$FIXTURES/boundary-node.ppl"
  "$FIXTURES/boundary-distribution.pp"
  "$FIXTURES/boundary-distribution.ppl"
)
[ -r "$REPL_INPUT" ] || { printf 'language parity: REPL fixture is not readable: %s\n' "$REPL_INPUT" >&2; exit 2; }
for fixture in "${BOUNDARY_FIXTURES[@]}"; do
  [ -r "$fixture" ] || { printf 'language parity: boundary fixture is not readable: %s\n' "$fixture" >&2; exit 2; }
done

failures=0
run_pair 'core-brace' 0 "$FIXTURES/core.pp" || failures=$((failures + 1))
run_pair 'core-sexpr' 0 "$FIXTURES/core.ppl" || failures=$((failures + 1))
run_pair 'definitions-brace' 0 "$FIXTURES/definitions.pp" || failures=$((failures + 1))
run_pair 'definitions-sexpr' 0 "$FIXTURES/definitions.ppl" || failures=$((failures + 1))
run_pair 'patterns-brace' 0 "$FIXTURES/patterns.pp" || failures=$((failures + 1))
run_pair 'patterns-sexpr' 0 "$FIXTURES/patterns.ppl" || failures=$((failures + 1))
run_pair 'type-error-brace' 1 "$FIXTURES/type-error.pp" || failures=$((failures + 1))
run_pair 'type-error-sexpr' 1 "$FIXTURES/type-error.ppl" || failures=$((failures + 1))
run_pair 'runtime-error-brace' 1 "$FIXTURES/runtime-error.pp" || failures=$((failures + 1))
run_pair 'runtime-error-sexpr' 1 "$FIXTURES/runtime-error.ppl" || failures=$((failures + 1))
run_stdin_pair 'multiline-repl' 0 "$REPL_INPUT" || failures=$((failures + 1))

# Run boundary fixtures for observability without treating them as pure rows.
# Candidate acceptance and clean rejection are both valid boundary outcomes.
# Abnormal process statuses remain failures.
run_boundary 'effects-brace' 'effect execution' "$FIXTURES/boundary-effects.pp" || failures=$((failures + 1))
run_boundary 'effects-sexpr' 'effect execution' "$FIXTURES/boundary-effects.ppl" || failures=$((failures + 1))
run_boundary 'node-brace' 'persistent node execution' "$FIXTURES/boundary-node.pp" || failures=$((failures + 1))
run_boundary 'node-sexpr' 'persistent node execution' "$FIXTURES/boundary-node.ppl" || failures=$((failures + 1))
run_boundary 'distribution-brace' 'island/distribution loading' "$FIXTURES/boundary-distribution.pp" || failures=$((failures + 1))
run_boundary 'distribution-sexpr' 'island/distribution loading' "$FIXTURES/boundary-distribution.ppl" || failures=$((failures + 1))

# Keep the existing metamorphic fuzzer as an optional bounded smoke seam.  It
# exercises the actual OCaml implementation only; --pp is explicit so this
# checker never falls back to a self-selected binary or self-golden output.
FUZZ="$ROOT/tools/fuzz.exe"
if [ -e "$FUZZ" ]; then
  if [ ! -x "$FUZZ" ]; then
    printf 'language parity: fuzzer exists but is not executable: %s\n' "$FUZZ" >&2
    failures=$((failures + 1))
  else
    printf 'CHECK bounded-fuzzer (OCaml --pp explicit)\n'
    set +e
    (cd "$ROOT" && "$FUZZ" --pp "$OCAML" --grammar core --seed 0 --count 16 \
      --max-depth 4 --timeout-ms 1000 --shrink-budget 24 --out "$TMP/fuzz-failures") \
      >"$TMP/fuzzer.out" 2>"$TMP/fuzzer.err"
    fuzz_status=$?
    set +e
    if [ "$fuzz_status" -eq 0 ]; then
      printf '  result: PASS (bounded OCaml metamorphic smoke)\n'
    else
      cat "$TMP/fuzzer.out" "$TMP/fuzzer.err"
      printf '  result: FAIL (fuzzer status %s)\n' "$fuzz_status"
      failures=$((failures + 1))
    fi
  fi
else
  printf 'CHECK bounded-fuzzer: SKIP (tools/fuzz.exe is not present)\n'
fi

if [ "$failures" -ne 0 ]; then
  printf 'language parity: FAIL (%s checks)\n' "$failures" >&2
  printf 'language parity: mismatches are against the selected OCaml reference; boundary observations are not parity passes.\n' >&2
  exit 1
fi
printf 'language parity: OK (shared pure corpus, statuses, stdout, diagnostics/ranges, multiline REPL; boundaries reported)\n'
exit 0
