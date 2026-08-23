#!/usr/bin/env bash
# Compare one shared pp test case (or the complete tests/ suite) against two
# explicitly selected engines.  This driver runs the existing .pp and .sh
# entry points; it never maintains a second copy of the test corpus.
#
# Examples (from the repository root):
#   scripts/compare-binaries.sh --ocaml _build/default/src/app/main.exe \
#     --lisp ./lisp/pp --case tests/001-eval-apply-test.pp
#   scripts/run-tests.sh --compare --ocaml ./pp-ocaml --lisp ./pp-lisp
#
# Each engine gets a fresh HOME and TMPDIR.  In addition to process exit status,
# stdout is compared byte-for-byte, stderr is compared after replacing only
# run-specific repository/sandbox prefixes, and every .pp/store tree created by
# the case is compared by relative inventory, size, and SHA-256 bytes.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
OCAML_BIN=""
LISP_BIN=""
CASE=""
SUITE=0
TIMEOUT_SECS="${TEST_CASE_TIMEOUT:-120}"
FUZZ_BIN="${FUZZ:-tools/fuzz.exe}"

usage() {
  cat >&2 <<'EOF'
usage: compare-binaries.sh --ocaml PATH --lisp PATH (--case FILE | --suite)

Run one existing tests/*.pp or tests/*.sh case, or every case in the shared
suite, once per explicitly selected binary.  --case is inferred from its .pp
or .sh suffix.  --timeout-secs defaults to TEST_CASE_TIMEOUT or 120.
EOF
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml) [ "$#" -ge 2 ] || usage; OCAML_BIN="$2"; shift 2 ;;
    --lisp) [ "$#" -ge 2 ] || usage; LISP_BIN="$2"; shift 2 ;;
    --case) [ "$#" -ge 2 ] || usage; CASE="$2"; shift 2 ;;
    --suite) SUITE=1; shift ;;
    --timeout-secs) [ "$#" -ge 2 ] || usage; TIMEOUT_SECS="$2"; shift 2 ;;
    --help|-h) usage ;;
    *) printf 'compare-binaries.sh: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done

[ -n "$OCAML_BIN" ] || { echo 'compare-binaries.sh: --ocaml is required' >&2; exit 2; }
[ -n "$LISP_BIN" ] || { echo 'compare-binaries.sh: --lisp is required' >&2; exit 2; }
[ "$SUITE" -eq 1 ] || [ -n "$CASE" ] || usage
[ "$SUITE" -eq 0 ] || [ -z "$CASE" ] || { echo 'compare-binaries.sh: use either --case or --suite' >&2; exit 2; }

absolute_binary() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$ROOT" "$1" ;;
  esac
}
OCAML_BIN=$(absolute_binary "$OCAML_BIN")
LISP_BIN=$(absolute_binary "$LISP_BIN")
[ -x "$OCAML_BIN" ] || { echo "compare-binaries.sh: OCaml binary is not executable: $OCAML_BIN" >&2; exit 2; }
[ -x "$LISP_BIN" ] || { echo "compare-binaries.sh: Lisp binary is not executable: $LISP_BIN" >&2; exit 2; }
FUZZ_BIN=$(absolute_binary "$FUZZ_BIN")

if [ -n "$CASE" ]; then
  case "$CASE" in
    /*) ;;
    *) CASE="$ROOT/$CASE" ;;
  esac
  [ -f "$CASE" ] || { echo "compare-binaries.sh: case not found: $CASE" >&2; exit 2; }
fi

run_bounded() {
  local seconds="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  elif command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
  else
    "$@" &
    local child=$!
    ( sleep "$seconds"; kill -TERM "$child" 2>/dev/null || exit 0; sleep 1; kill -KILL "$child" 2>/dev/null || true ) &
    local watchdog=$!
    wait "$child"; local status=$?
    kill "$watchdog" 2>/dev/null || true
    wait "$watchdog" 2>/dev/null || true
    return "$status"
  fi
}

snapshot_stores() {
  # Store roots may live below random host names.  Compare the multiset of
  # relative entries instead of the random root path; duplicate entries
  # preserve inventory when a case intentionally creates multiple stores.
  local sandbox="$1" output="$2" store count directory file rel bytes digest
  : > "$output"
  count=0
  while IFS= read -r store; do
    [ -n "$store" ] || continue
    while IFS= read -r directory; do
      [ -n "$directory" ] || continue
      rel="${directory#"$store"/}"
      printf '%s/	DIR	-\n' "$rel" >> "$output"
    done < <(find "$store" -mindepth 1 -type d -print | LC_ALL=C sort)
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      rel="${file#"$store"/}"
      bytes=$(wc -c < "$file")
      digest=$(sha256sum "$file" | cut -d' ' -f1)
      printf '%s\t%s\t%s\n' "$rel" "$bytes" "$digest" >> "$output"
    done < <(find "$store" -type f -print | LC_ALL=C sort)
    count=$((count + 1))
  done < <(find "$sandbox" -type d -path '*/.pp/store' -print | LC_ALL=C sort)
  if [ "$count" -eq 0 ]; then
    printf '(no store supplied by case)\n' > "$output"
  else
    LC_ALL=C sort -o "$output" "$output"
  fi
}

normalize_stderr() {
  local input="$1" output="$2" sandbox="$3" text
  # Keep trailing newlines: command substitution normally strips them, so a
  # sentinel is appended before capturing the stream.
  text=$(cat "$input"; printf '\001')
  text=${text%$'\001'}
  # Bash's exact-substring replacement leaves diagnostic line/column ranges
  # untouched while making per-engine sandbox and repository prefixes stable.
  text=${text//"$sandbox"/<sandbox>}
  text=${text//"$ROOT"/<repo>}
  printf '%s' "$text" > "$output"
}

run_engine() {
  local label="$1" binary="$2" case_file="$3" result_root="$4"
  local sandbox="$result_root/$label" home="$result_root/$label/home" tmp="$result_root/$label/tmp"
  local out="$result_root/$label/stdout" err="$result_root/$label/stderr" status
  mkdir -p "$home" "$tmp"
  if [[ "$case_file" == *.pp ]]; then
    (
      cd "$ROOT" || exit 125
      export HOME="$home" TMPDIR="$tmp" PP="$binary"
      export PP_OCAML="$OCAML_BIN" PP_LISP="$LISP_BIN" FUZZ="$FUZZ_BIN"
      run_bounded "$TIMEOUT_SECS" "$binary" "$case_file"
    ) >"$out" 2>"$err"
  elif [[ "$case_file" == *.sh ]]; then
    (
      cd "$ROOT" || exit 125
      export HOME="$home" TMPDIR="$tmp" PP="$binary"
      export PP_OCAML="$OCAML_BIN" PP_LISP="$LISP_BIN" FUZZ="$FUZZ_BIN"
      run_bounded "$TIMEOUT_SECS" bash "$case_file"
    ) >"$out" 2>"$err"
  else
    echo "compare-binaries.sh: unsupported case suffix: $case_file" >&2
    return 2
  fi
  status=$?
  printf '%s\n' "$status" > "$result_root/$label/status"
  snapshot_stores "$sandbox" "$result_root/$label/store"
}


compare_case() {
  local case_file="$1" case_name
  case_name="${case_file#$ROOT/}"
  local run_root
  run_root=$(mktemp -d)
  run_engine ocaml "$OCAML_BIN" "$case_file" "$run_root"
  run_engine lisp "$LISP_BIN" "$case_file" "$run_root"
  local ocaml_status lisp_status ocaml_err_norm lisp_err_norm failed=0
  ocaml_status=$(cat "$run_root/ocaml/status")
  lisp_status=$(cat "$run_root/lisp/status")
  ocaml_err_norm="$run_root/ocaml/stderr.normalized"
  lisp_err_norm="$run_root/lisp/stderr.normalized"
  normalize_stderr "$run_root/ocaml/stderr" "$ocaml_err_norm" "$run_root/ocaml"
  normalize_stderr "$run_root/lisp/stderr" "$lisp_err_norm" "$run_root/lisp"
  printf 'CASE %s\n' "$case_name"
  if [ "$ocaml_status" = "$lisp_status" ]; then
    printf 'exit status: match (%s)\n' "$ocaml_status"
  else
    printf 'exit status: DIFFER (ocaml=%s lisp=%s)\n' "$ocaml_status" "$lisp_status"
    failed=1
  fi
  if cmp -s "$run_root/ocaml/stdout" "$run_root/lisp/stdout"; then
    echo 'stdout: match'
  else
    echo 'stdout: DIFFER'
    diff -u --label ocaml --label lisp "$run_root/ocaml/stdout" "$run_root/lisp/stdout" || true
    failed=1
  fi
  if cmp -s "$ocaml_err_norm" "$lisp_err_norm"; then
    echo 'stderr (normalized diagnostics): match'
  else
    echo 'stderr (normalized diagnostics): DIFFER'
    diff -u --label ocaml --label lisp "$ocaml_err_norm" "$lisp_err_norm" || true
    failed=1
  fi
  if cmp -s "$run_root/ocaml/store" "$run_root/lisp/store"; then
    echo 'store inventory/bytes: match'
  else
    echo 'store inventory/bytes: DIFFER'
    diff -u --label ocaml --label lisp "$run_root/ocaml/store" "$run_root/lisp/store" || true
    failed=1
  fi
  if [ "$failed" -eq 0 ]; then
    echo "PARITY PASS $case_name"
  else
    echo "PARITY FAIL $case_name"
  fi
  rm -rf "$run_root"
  return "$failed"
}

fail=0
if [ "$SUITE" -eq 1 ]; then
  shopt -s nullglob
  cases=("$ROOT"/tests/[0-9]*.pp)
  for file in "$ROOT"/tests/*.sh; do
    [ "$(basename "$file")" = lib.sh ] && continue
    cases+=("$file")
  done
  shopt -u nullglob
  for file in "${cases[@]}"; do
    compare_case "$file" || fail=1
  done
else
  compare_case "$CASE" || fail=1
fi
exit "$fail"
