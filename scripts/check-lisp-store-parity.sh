#!/usr/bin/env bash
# Compare shared durable runs without checked-in output or lock files.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
FIXTURES="$ROOT/lisp/tests/store/parity"
OCAML=""
LISP=""
TIMEOUT_SECONDS=20

usage() {
  cat >&2 <<'EOF'
usage: scripts/check-lisp-store-parity.sh --ocaml PATH --lisp PATH [--timeout-seconds N]

Both binaries are required.  The checker runs shared store fixtures and compares
exit status, stdout, normalized diagnostics, layout/inventory, and every durable
byte in VERSION, objects, blobs, traces, cells carried by traces, and gc roots.
Locks and their metadata are excluded.  Effects, distribution, transport,
reconciliation, and crash injection remain explicit boundaries of this checker.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml)
      [ "$#" -ge 2 ] || { echo 'store parity: --ocaml requires a path' >&2; exit 2; }
      OCAML=$2; shift 2 ;;
    --lisp)
      [ "$#" -ge 2 ] || { echo 'store parity: --lisp requires a path' >&2; exit 2; }
      LISP=$2; shift 2 ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || { echo 'store parity: --timeout-seconds requires a value' >&2; exit 2; }
      TIMEOUT_SECONDS=$2; shift 2 ;;
    -h|--help)
      usage >&2; exit 0 ;;
    *)
      echo "store parity: unrecognized argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[ -n "$OCAML" ] && [ -n "$LISP" ] || { usage; exit 2; }
case "$OCAML" in
  /*) ;;
  *) OCAML="$ROOT/$OCAML" ;;
esac
case "$LISP" in
  /*) ;;
  *) LISP="$ROOT/$LISP" ;;
esac
[ -x "$OCAML" ] || { printf 'store parity: OCaml executable is not executable: %s\n' "$OCAML" >&2; exit 2; }
[ -x "$LISP" ] || { printf 'store parity: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) printf 'store parity: timeout must be an integer: %s\n' "$TIMEOUT_SECONDS" >&2; exit 2 ;;
esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || { echo 'store parity: timeout must be positive' >&2; exit 2; }

for fixture in cold-warm.pp failure.pp authority.pp why-gc.pp reconcile.pp data.txt; do
  [ -r "$FIXTURES/$fixture" ] || {
    printf 'store parity: fixture is not readable: %s\n' "$FIXTURES/$fixture" >&2
    exit 2
  }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-store-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
WORK="$TMP/work"
mkdir -p "$WORK" "$TMP/home-ocaml" "$TMP/home-lisp"
cp -R "$FIXTURES"/. "$WORK"/
sed -i "s|__DATA__|$WORK/data.txt|g" "$WORK/authority.pp" "$WORK/why-gc.pp"

normalize_stderr() {
  local input=$1 output=$2
  sed \
    -e "s|$FIXTURES|<fixtures>|g" \
    -e "s|$ROOT|<repo>|g" \
    -e "s|$WORK|<work>|g" \
    -e "s|$TMP|<tmp>|g" \
    -e 's/\r$//' \
    "$input" >"$output"
}

run_process() {
  local engine=$1 home=$2 output=$3 error=$4
  shift 4
  (cd "$WORK" && HOME="$home" timeout --signal=TERM "${TIMEOUT_SECONDS}s" \
    "$engine" "$@") >"$output" 2>"$error"
}

store_manifest() {
  local home=$1 output=$2 root
  root="$home/.pp/store"
  : >"$output"
  [ -d "$root" ] || return 0
  (
    cd "$root" || exit 1
    find . -mindepth 1 \
      \( -path './locks' -o -path './locks/*' \) -prune -o \
      \( -type d -printf 'D\t%P\n' -o -type f -printf 'F\t%P\n' \)
  ) | sort >"$output"
}

compare_store() {
  local label=$1 first=$2 second=$3
  local one="$TMP/$label.ocaml.store" two="$TMP/$label.lisp.store"
  local kind path failures=0
  store_manifest "$first" "$one"
  store_manifest "$second" "$two"
  if ! cmp -s "$one" "$two"; then
    printf '  store layout/inventory: DIFFER\n'
    diff -u --label ocaml --label lisp "$one" "$two" || true
    failures=$((failures + 1))
  else
    printf '  store layout/inventory: match\n'
  fi
  while IFS=$'\t' read -r kind path; do
    [ "$kind" = F ] || continue
    if ! cmp -s "$first/.pp/store/$path" "$second/.pp/store/$path"; then
      printf '  store bytes: DIFFER (%s)\n' "$path"
      printf '    ocaml: '; sha256sum -- "$first/.pp/store/$path" | cut -d' ' -f1
      printf '    lisp:  '; sha256sum -- "$second/.pp/store/$path" | cut -d' ' -f1
      failures=$((failures + 1))
    fi
  done <"$one"
  if [ "$failures" -eq 0 ]; then
    printf '  store bytes: match (VERSION, objects, blobs, traces/cells, gc roots)\n'
  fi
  return "$failures"
}

require_store_shape() {
  local label=$1 home=$2 manifest
  manifest="$TMP/$label.$(basename "$home").shape"
  store_manifest "$home" "$manifest"
  local failure=0
  for expected in $'F\tVERSION' $'D\tobjects' $'D\ttraces'; do
    if ! grep -Fqx "$expected" "$manifest"; then
      printf '  store shape: missing %s\n' "$expected"
      failure=1
    fi
  done
  for prefix in $'F\tobjects/' $'F\ttraces/'; do
    if ! grep -Fq "$prefix" "$manifest"; then
      printf '  store shape: missing %s\n' "$prefix"
      failure=1
    fi
  done
  return "$failure"
}
require_blob_shape() {
  local label=$1 home=$2 manifest
  manifest="$TMP/$label.$(basename "$home").blobs"
  store_manifest "$home" "$manifest"
  local failure=0
  for expected in $'D\tblobs'; do
    if ! grep -Fqx "$expected" "$manifest"; then
      printf '  store shape: missing %s\n' "$expected"
      failure=1
    fi
  done
  if ! grep -Fq $'F\tblobs/' "$manifest"; then
    printf '  store shape: missing F\tblobs/\n'
    failure=1
  fi
  return "$failure"
}

run_pair() {
  local label=$1 expected=$2
  shift 2
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local ocaml_status lisp_status failures=0

  set +e
  run_process "$OCAML" "$TMP/home-ocaml" "$ocaml_out" "$ocaml_err" "$@"
  ocaml_status=$?
  run_process "$LISP" "$TMP/home-lisp" "$lisp_out" "$lisp_err" "$@"
  lisp_status=$?
  printf '%s\n' "$ocaml_status" >"$TMP/$label.ocaml.status"
  printf '%s\n' "$lisp_status" >"$TMP/$label.lisp.status"
  normalize_stderr "$ocaml_err" "$ocaml_norm"
  normalize_stderr "$lisp_err" "$lisp_norm"

  printf 'CHECK %s\n' "$label"
  if [ "$ocaml_status" -eq "$lisp_status" ]; then
    printf '  exit status: match (%s)\n' "$ocaml_status"
  else
    printf '  exit status: DIFFER (ocaml=%s lisp=%s)\n' "$ocaml_status" "$lisp_status"
    failures=$((failures + 1))
  fi
  if [ "$ocaml_status" -eq "$expected" ] && [ "$lisp_status" -eq "$expected" ]; then
    printf '  expected status: %s\n' "$expected"
  else
    printf '  expected status: DIFFER (required=%s)\n' "$expected"
    failures=$((failures + 1))
  fi
  if cmp -s "$ocaml_out" "$lisp_out"; then
    printf '  stdout: match\n'
  else
    printf '  stdout: DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_out" "$lisp_out" || true
    failures=$((failures + 1))
  fi
  if cmp -s "$ocaml_norm" "$lisp_norm"; then
    printf '  stderr (normalized diagnostics/ranges): match\n'
  else
    printf '  stderr (normalized diagnostics/ranges): DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_norm" "$lisp_norm" || true
    failures=$((failures + 1))
  fi
  if [ "$expected" -eq 0 ] &&
     [ ! -s "$ocaml_out" ] && [ ! -s "$ocaml_err" ]; then
    printf '  reference output: unexpectedly empty\n'
    failures=$((failures + 1))
  elif [ "$expected" -ne 0 ] && [ ! -s "$ocaml_norm" ]; then
    printf '  reference stderr: unexpectedly empty\n'
    failures=$((failures + 1))
  fi
  compare_store "$label" "$TMP/home-ocaml" "$TMP/home-lisp" || failures=$((failures + 1))
  if [ "$failures" -ne 0 ]; then
    printf '  result: FAIL\n'
    return 1
  fi
  printf '  result: PASS\n'
  return 0
}

combined_contains() {
  local output=$1 error=$2 pattern=$3
  grep -Eq "$pattern" "$output" || grep -Eq "$pattern" "$error"
}

assert_contains() {
  local output=$1 error=$2 pattern=$3 label=$4
  if combined_contains "$output" "$error" "$pattern"; then
    printf '  %s: observed\n' "$label"
    return 0
  fi
  printf '  %s: missing (%s)\n' "$label" "$pattern"
  return 1
}

failures=0
run_pair 'cold' 0 cold-warm.pp || failures=$((failures + 1))
assert_contains "$TMP/cold.ocaml.out" "$TMP/cold.ocaml.err" 'COMPUTE' 'cold body execution' || failures=$((failures + 1))
require_store_shape 'cold' "$TMP/home-ocaml" || failures=$((failures + 1))
require_store_shape 'cold' "$TMP/home-lisp" || failures=$((failures + 1))

run_pair 'warm' 0 cold-warm.pp || failures=$((failures + 1))
if combined_contains "$TMP/warm.ocaml.out" "$TMP/warm.ocaml.err" 'COMPUTE' ||
   combined_contains "$TMP/warm.lisp.out" "$TMP/warm.lisp.err" 'COMPUTE'; then
  printf '  warm body execution: unexpected\n'
  failures=$((failures + 1))
else
  printf '  warm body execution: skipped\n'
fi

run_pair 'failure-cold' 1 failure.pp || failures=$((failures + 1))
assert_contains "$TMP/failure-cold.ocaml.out" "$TMP/failure-cold.ocaml.err" 'ATTEMPT' 'failure body execution' || failures=$((failures + 1))
run_pair 'failure-warm' 1 failure.pp || failures=$((failures + 1))
if combined_contains "$TMP/failure-warm.ocaml.out" "$TMP/failure-warm.ocaml.err" 'ATTEMPT' ||
   combined_contains "$TMP/failure-warm.lisp.out" "$TMP/failure-warm.lisp.err" 'ATTEMPT'; then
  printf '  failure replay: unexpected body execution\n'
  failures=$((failures + 1))
else
  printf '  failure replay: body skipped\n'
fi

run_pair 'authority-cold' 0 --grant "fs:$WORK:ro" authority.pp || failures=$((failures + 1))
assert_contains "$TMP/authority-cold.ocaml.out" "$TMP/authority-cold.ocaml.err" 'STORE-DATA-V1' 'authorized value' || failures=$((failures + 1))
require_blob_shape 'authority-cold' "$TMP/home-ocaml" || failures=$((failures + 1))
require_blob_shape 'authority-cold' "$TMP/home-lisp" || failures=$((failures + 1))
run_pair 'authority-miss' 1 --grant "fs:$TMP/unrelated:ro" authority.pp || failures=$((failures + 1))
if combined_contains "$TMP/authority-miss.ocaml.out" "$TMP/authority-miss.ocaml.err" 'STORE-DATA-V1' ||
   combined_contains "$TMP/authority-miss.lisp.out" "$TMP/authority-miss.lisp.err" 'STORE-DATA-V1'; then
  printf '  authority miss: secret leak\n'
  failures=$((failures + 1))
else
  printf '  authority miss: value withheld\n'
fi
run_pair 'authority-hit' 0 --grant "fs:$WORK:ro" authority.pp || failures=$((failures + 1))

run_pair 'why-cold' 0 why --grant "fs:$WORK:ro" why-gc.pp || failures=$((failures + 1))
run_pair 'why-warm' 0 why --grant "fs:$WORK:ro" why-gc.pp || failures=$((failures + 1))
printf 'STORE-DATA-V2\n' >"$WORK/data.txt"
run_pair 'why-stale' 0 why --grant "fs:$WORK:ro" why-gc.pp || failures=$((failures + 1))
assert_contains "$TMP/why-stale.ocaml.norm" "$TMP/why-stale.ocaml.norm" 'stale' 'why stale observation' || failures=$((failures + 1))
run_pair 'gc' 0 gc --gc-grace-seconds 0 || failures=$((failures + 1))

printf 'BOUNDARY process/effects: not asserted by store parity\n'
printf 'BOUNDARY distribution/transport: not asserted by store parity\n'
printf 'BOUNDARY reconciliation: not asserted by store parity\n'
printf 'BOUNDARY crash injection: covered by the separate crash gate\n'

if [ "$failures" -ne 0 ]; then
  printf 'store parity: FAIL (%s checks)\n' "$failures" >&2
  exit 1
fi
printf 'store parity: OK (shared fixtures, statuses, diagnostics, layout/inventory, durable bytes, replay, authority, why, gc; explicit boundaries)\n'
exit 0
