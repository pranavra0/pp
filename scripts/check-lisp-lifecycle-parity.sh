#!/usr/bin/env bash
# Compare lifecycle and distribution boundaries with independent stores.
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURES="$ROOT/lisp/tests/lifecycle"
OCAML=""
LISP=""
TIMEOUT_SECONDS=20
TMP=""
WORK=""
SHARED_ROOT=""
HOME_OCAML=""
HOME_LISP=""
failures=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/check-lisp-lifecycle-parity.sh --ocaml PATH --lisp PATH [--timeout-seconds N]

Both binaries are required. Shared lifecycle fixtures compare exit status,
stdout, normalized diagnostics, materialized trees, and durable store bytes.
Unsupported lifecycle/distribution services are reported as BOUNDARY. A signal
or timeout is always a failure.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ocaml)
      [ "$#" -ge 2 ] || { echo 'lifecycle parity: --ocaml requires a path' >&2; exit 2; }
      OCAML=$2; shift 2 ;;
    --lisp)
      [ "$#" -ge 2 ] || { echo 'lifecycle parity: --lisp requires a path' >&2; exit 2; }
      LISP=$2; shift 2 ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || { echo 'lifecycle parity: --timeout-seconds requires a value' >&2; exit 2; }
      TIMEOUT_SECONDS=$2; shift 2 ;;
    -h|--help)
      usage >&2; exit 0 ;;
    *)
      echo "lifecycle parity: unrecognized argument: $1" >&2
      usage
      exit 2 ;;
  esac
done

[ -n "$OCAML" ] && [ -n "$LISP" ] || { usage; exit 2; }
case "$OCAML" in /*) ;; *) OCAML="$ROOT/$OCAML" ;; esac
case "$LISP" in /*) ;; *) LISP="$ROOT/$LISP" ;; esac
[ -x "$OCAML" ] || { printf 'lifecycle parity: OCaml executable is not executable: %s\n' "$OCAML" >&2; exit 2; }
[ -x "$LISP" ] || { printf 'lifecycle parity: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) echo 'lifecycle parity: timeout must be an integer' >&2; exit 2;; esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || { echo 'lifecycle parity: timeout must be positive' >&2; exit 2; }
command -v timeout >/dev/null 2>&1 || { echo 'lifecycle parity: timeout executable is required' >&2; exit 2; }

for fixture in reconcile.pp blob-reconcile.pp sandbox.pp gc.pp watch.pp schedule.pp \
               fenced.pp process.pp transport.pp network.pp; do
  [ -r "$FIXTURES/$fixture" ] || {
    printf 'lifecycle parity: fixture is not readable: %s\n' "$FIXTURES/$fixture" >&2
    exit 2
  }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-lifecycle-parity.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
WORK="$TMP/work"
mkdir -p "$WORK" "$TMP/home-ocaml" "$TMP/home-lisp" "$TMP/shared"
HOME_OCAML="$TMP/home-ocaml"
HOME_LISP="$TMP/home-lisp"
SHARED_ROOT="$WORK/root"
mkdir -p "$WORK"

normalize_text() {
  local input=$1 output=$2
  sed \
    -e "s|$FIXTURES|<fixtures>|g" \
    -e "s|$ROOT|<repo>|g" \
    -e "s|$WORK|<work>|g" \
    -e "s|$TMP|<tmp>|g" \
    -e 's/\r$//' \
    "$input" >"$output"
}
normalize_journal() {
  local input=$1 output=$2
  sed -E \
    -e 's/^intent fenced [0-9a-f]{64} [0-9a-f]{64} /intent fenced <action> <epoch> /' \
    -e 's/^done fenced [0-9a-f]{64} /done fenced <action> /' \
    "$input" >"$output"
}

reset_homes() {
  rm -rf "$HOME_OCAML/.pp" "$HOME_LISP/.pp"
  mkdir -p "$HOME_OCAML" "$HOME_LISP"
}


reset_root() {
  rm -rf "$SHARED_ROOT"
  mkdir -p "$SHARED_ROOT"
}

materialize_args() {
  local root=$1 item
  shift
  MATERIALIZED_ARGS=()
  for item in "$@"; do
    MATERIALIZED_ARGS+=("${item//__ROOT__/$root}")
  done
}

run_engine() {
  local engine=$1 home=$2 output=$3 error=$4 root=$5
  shift 5
  materialize_args "$root" "$@"
  (cd "$WORK" && HOME="$home" timeout --signal=TERM --kill-after=2 "${TIMEOUT_SECONDS}s" \
    "$engine" "${MATERIALIZED_ARGS[@]}") >"$output" 2>"$error"
}

status_is_abort() {
  case "$1" in
    124|125|126|127|12[89]|1[3-9][0-9]|[2-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
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
  local path failures_here=0
  store_manifest "$first" "$one"
  store_manifest "$second" "$two"
  if cmp -s "$one" "$two"; then
    printf '  store layout/inventory: match\n'
  else
    printf '  store layout/inventory: DIFFER\n'
    diff -u --label ocaml --label lisp "$one" "$two" || true
    failures_here=$((failures_here + 1))
  fi
  while IFS=$'\t' read -r kind path; do
    [ "$kind" = F ] || continue
    if [ ! -f "$second/.pp/store/$path" ]; then
      printf '  store bytes: missing in lisp (%s)\n' "$path"
      failures_here=$((failures_here + 1))
      continue
    fi
    local first_bytes="$first/.pp/store/$path"
    local second_bytes="$second/.pp/store/$path"
    local first_compare="$first_bytes" second_compare="$second_bytes"
    if [ "$path" = "journal/log" ]; then
      first_compare="$TMP/$label.ocaml.journal"
      second_compare="$TMP/$label.lisp.journal"
      normalize_journal "$first_bytes" "$first_compare"
      normalize_journal "$second_bytes" "$second_compare"
    fi
    if ! cmp -s "$first_compare" "$second_compare"; then
      printf '  store bytes: DIFFER (%s)\n' "$path"
      printf '    ocaml: '; sha256sum -- "$first_bytes" | cut -d' ' -f1
      printf '    lisp:  '; sha256sum -- "$second_bytes" | cut -d' ' -f1
      failures_here=$((failures_here + 1))
    fi
  done <"$one"
  while IFS=$'\t' read -r kind path; do
    [ "$kind" = F ] || continue
    if [ ! -f "$first/.pp/store/$path" ]; then
      printf '  store bytes: missing in ocaml (%s)\n' "$path"
      failures_here=$((failures_here + 1))
    fi
  done <"$two"
  if [ "$failures_here" -eq 0 ]; then
    printf '  store bytes: match\n'
  fi
  return "$failures_here"
}



require_store_files() {
  local label=$1 manifest
  local missing=0
  for manifest in "$TMP/$label.ocaml.store" "$TMP/$label.lisp.store"; do
    for required in $'F	VERSION' $'F	journal/log'; do
      if ! grep -Fqx "$required" "$manifest"; then
        printf '  %s: missing %s in %s\n' "$label" "$required" "$manifest"
        missing=$((missing + 1))
      fi
    done
  done
  return "$missing"
}
root_snapshot() {
  local root=$1 output=$2
  : >"$output"
  [ -d "$root" ] || return 0
  (
    cd "$root" || exit 1
    find . -mindepth 1 \
      \( -type d -printf 'D\t%P\n' \
         -o -type l -printf 'L\t%P\t%l\n' \
         -o -type f -printf 'F\t%P\t' -exec sha256sum {} \; \)
  ) | sed 's/[[:space:]]\+/\t/g' | sort >"$output"
}

require_tree_digest() {
  local label=$1 path=$2 content=$3 expected side missing=0
  expected=$(printf '%s' "$content" | sha256sum | cut -d' ' -f1)
  for side in ocaml lisp; do
    if ! grep -Fq $'F\t'"$path"$'\t'"$expected" "$TMP/$label.$side.root"; then
      printf '  %s materialization: wrong bytes for %s (%s)\n' "$label" "$path" "$side"
      missing=$((missing + 1))
    fi
  done
  return "$missing"
}
combined_contains() {
  local output=$1 error=$2 pattern=$3
  grep -Eq "$pattern" "$output" || grep -Eq "$pattern" "$error"
}

compare_pair_results() {
  local label=$1 expected=$2 ocaml_status=$3 lisp_status=$4
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local local_fail=0

  printf 'CHECK %s\n' "$label"
  if status_is_abort "$ocaml_status" || status_is_abort "$lisp_status"; then
    printf '  result: FAIL (signal/timeout ocaml=%s lisp=%s)\n' "$ocaml_status" "$lisp_status"
    return 1
  fi
  if [ "$ocaml_status" -eq "$lisp_status" ]; then
    printf '  exit status: match (%s)\n' "$ocaml_status"
  else
    printf '  exit status: DIFFER (ocaml=%s lisp=%s)\n' "$ocaml_status" "$lisp_status"
    local_fail=$((local_fail + 1))
  fi
  if [ "$ocaml_status" -eq "$expected" ] && [ "$lisp_status" -eq "$expected" ]; then
    printf '  expected status: %s\n' "$expected"
  else
    printf '  expected status: DIFFER (required=%s)\n' "$expected"
    local_fail=$((local_fail + 1))
  fi
  if cmp -s "$ocaml_out" "$lisp_out"; then
    printf '  stdout: match\n'
  else
    printf '  stdout: DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_out" "$lisp_out" || true
    local_fail=$((local_fail + 1))
  fi
  if cmp -s "$ocaml_norm" "$lisp_norm"; then
    printf '  stderr (normalized diagnostics/ranges): match\n'
  else
    printf '  stderr (normalized diagnostics/ranges): DIFFER\n'
    diff -u --label ocaml --label lisp "$ocaml_norm" "$lisp_norm" || true
    local_fail=$((local_fail + 1))
  fi
  if cmp -s "$TMP/$label.ocaml.root" "$TMP/$label.lisp.root"; then
    printf '  materialized tree: match\n'
  else
    printf '  materialized tree: DIFFER\n'
    diff -u --label ocaml --label lisp "$TMP/$label.ocaml.root" "$TMP/$label.lisp.root" || true
    local_fail=$((local_fail + 1))
  fi
  compare_store "$label" "$HOME_OCAML" "$HOME_LISP" || local_fail=$((local_fail + 1))
  if [ "$local_fail" -ne 0 ]; then
    printf '  result: FAIL\n'
    return 1
  fi
  printf '  result: PASS\n'
  return 0
}

run_pair() {
  local label=$1 expected=$2
  shift 2
  local ocaml_out="$TMP/$label.ocaml.out" lisp_out="$TMP/$label.lisp.out"
  local ocaml_err="$TMP/$label.ocaml.err" lisp_err="$TMP/$label.lisp.err"
  local ocaml_norm="$TMP/$label.ocaml.norm" lisp_norm="$TMP/$label.lisp.norm"
  local ocaml_status lisp_status

  reset_root
  set +e
  run_engine "$OCAML" "$HOME_OCAML" "$ocaml_out" "$ocaml_err" "$SHARED_ROOT" "$@"
  ocaml_status=$?
  root_snapshot "$SHARED_ROOT" "$TMP/$label.ocaml.root"
  reset_root
  run_engine "$LISP" "$HOME_LISP" "$lisp_out" "$lisp_err" "$SHARED_ROOT" "$@"
  lisp_status=$?
  set +e
  root_snapshot "$SHARED_ROOT" "$TMP/$label.lisp.root"
  normalize_text "$ocaml_err" "$ocaml_norm"
  normalize_text "$lisp_err" "$lisp_norm"
  compare_pair_results "$label" "$expected" "$ocaml_status" "$lisp_status"
}

service_unavailable() {
  local status=$1 output=$2 error=$3
  [ "$status" -ne 0 ] || return 1
  combined_contains "$output" "$error" 'unavailable|not installed|unsupported|not available'
}

run_local_case() {
  local label=$1 expected=$2
  shift 2
  local file_label=${label//\//_}
  file_label=${file_label// /_}
  local ocaml_out="$TMP/$file_label.ocaml.out" lisp_out="$TMP/$file_label.lisp.out"
  local ocaml_err="$TMP/$file_label.ocaml.err" lisp_err="$TMP/$file_label.lisp.err"
  local ocaml_norm="$TMP/$file_label.ocaml.norm" lisp_norm="$TMP/$file_label.lisp.norm"
  local ocaml_status lisp_status

  reset_homes
  reset_root
  set +e
  run_engine "$OCAML" "$HOME_OCAML" "$ocaml_out" "$ocaml_err" "$SHARED_ROOT" "$@"
  ocaml_status=$?
  root_snapshot "$SHARED_ROOT" "$TMP/$file_label.ocaml.root"
  reset_root
  run_engine "$LISP" "$HOME_LISP" "$lisp_out" "$lisp_err" "$SHARED_ROOT" "$@"
  lisp_status=$?
  root_snapshot "$SHARED_ROOT" "$TMP/$file_label.lisp.root"
  normalize_text "$ocaml_err" "$ocaml_norm"
  normalize_text "$lisp_err" "$lisp_norm"

  if status_is_abort "$ocaml_status" || status_is_abort "$lisp_status"; then
    printf 'CHECK %s\n  result: FAIL (signal/timeout ocaml=%s lisp=%s)\n' \
      "$label" "$ocaml_status" "$lisp_status"
    return 1
  fi
  compare_pair_results "$file_label" "$expected" "$ocaml_status" "$lisp_status"
}
run_host_boundary_case() {
  local label=$1 expected=$2 rejection=$3 file_label
  file_label=${label//\//_}
  file_label=${file_label// /_}
  shift 3
  local ocaml_out="$TMP/$file_label.ocaml.out" lisp_out="$TMP/$file_label.lisp.out"
  local ocaml_err="$TMP/$file_label.ocaml.err" lisp_err="$TMP/$file_label.lisp.err"
  local ocaml_norm="$TMP/$file_label.ocaml.norm" lisp_norm="$TMP/$file_label.lisp.norm"
  local ocaml_status lisp_status

  reset_homes
  reset_root
  set +e
  run_engine "$OCAML" "$HOME_OCAML" "$ocaml_out" "$ocaml_err" "$SHARED_ROOT" "$@"
  ocaml_status=$?
  root_snapshot "$SHARED_ROOT" "$TMP/$file_label.ocaml.root"
  reset_root
  run_engine "$LISP" "$HOME_LISP" "$lisp_out" "$lisp_err" "$SHARED_ROOT" "$@"
  lisp_status=$?
  root_snapshot "$SHARED_ROOT" "$TMP/$file_label.lisp.root"
  normalize_text "$ocaml_err" "$ocaml_norm"
  normalize_text "$lisp_err" "$lisp_norm"

  if status_is_abort "$ocaml_status" || status_is_abort "$lisp_status"; then
    printf 'CHECK %s\n  result: FAIL (signal/timeout ocaml=%s lisp=%s)\n' \
      "$label" "$ocaml_status" "$lisp_status"
    return 1
  fi
  if [ "$lisp_status" -ne "$expected" ] ||
     service_unavailable "$lisp_status" "$lisp_out" "$lisp_err"; then
    printf 'CHECK %s\n  result: FAIL (Lisp did not complete expected operation: status=%s expected=%s)\n' \
      "$label" "$lisp_status" "$expected"
    return 1
  fi
  if [ "$expected" -eq 1 ] &&
     ! combined_contains "$lisp_out" "$lisp_err" "$rejection"; then
    printf 'CHECK %s\n  result: FAIL (Lisp rejection was not clean)\n' "$label"
    return 1
  fi
  if [ "$ocaml_status" -ne 0 ] &&
     combined_contains "$ocaml_out" "$ocaml_err" "$rejection"; then
    printf 'BOUNDARY %s: OCaml reference cleanly rejects host-boundary operation (ocaml=%s lisp=%s)\n' \
      "$label" "$ocaml_status" "$lisp_status"
    return 0
  fi
  compare_pair_results "$file_label" "$expected" "$ocaml_status" "$lisp_status"
}


run_boundary() {
  local label=$1 file_label
  file_label=${label//\//_}
  file_label=${file_label// /_}
  shift
  local ocaml_out="$TMP/$file_label.ocaml.out" lisp_out="$TMP/$file_label.lisp.out"
  local ocaml_err="$TMP/$file_label.ocaml.err" lisp_err="$TMP/$file_label.lisp.err"
  local ocaml_status lisp_status
  reset_homes
  reset_root
  set +e
  run_engine "$OCAML" "$HOME_OCAML" "$ocaml_out" "$ocaml_err" "$SHARED_ROOT" "$@"
  ocaml_status=$?
  reset_root
  run_engine "$LISP" "$HOME_LISP" "$lisp_out" "$lisp_err" "$SHARED_ROOT" "$@"
  lisp_status=$?
  set +e
  if status_is_abort "$ocaml_status" || status_is_abort "$lisp_status"; then
    printf 'BOUNDARY %s: FAIL signal/timeout (ocaml=%s lisp=%s)\n' "$label" "$ocaml_status" "$lisp_status"
    return 1
  fi
  if ! service_unavailable "$lisp_status" "$lisp_out" "$lisp_err"; then
    printf 'BOUNDARY %s: FAIL Lisp did not report an intentional unsupported service (status=%s)\n' "$label" "$lisp_status"
    return 1
  fi
  printf 'BOUNDARY %s: Lisp service unavailable (ocaml=%s lisp=%s)\n' "$label" "$ocaml_status" "$lisp_status"
  return 0
}

SANDBOX_FIXTURE="$TMP/sandbox.pp"
sed "s|__ESCAPE__|$WORK/escape|g" "$FIXTURES/sandbox.pp" >"$SANDBOX_FIXTURE"

# Reconcile and restore a blob-backed tree.
run_pair reconcile 0 --grant "fs:__ROOT__:rw" --reconcile __ROOT__ "$FIXTURES/reconcile.pp" || failures=$((failures + 1))
if grep -Fq $'F\tmanaged.txt\t' "$TMP/reconcile.lisp.root"; then
  printf '  reconcile materialization: present\n'
else
  printf '  reconcile materialization: missing\n'
  failures=$((failures + 1))
fi
require_tree_digest reconcile managed.txt LIFECYCLE-A || failures=$((failures + 1))
require_store_files reconcile || failures=$((failures + 1))
run_pair blob-cold 0 --grant "fs:__ROOT__:rw" --reconcile __ROOT__ "$FIXTURES/blob-reconcile.pp" || failures=$((failures + 1))
run_pair blob-warm 0 --grant "fs:__ROOT__:rw" --reconcile __ROOT__ "$FIXTURES/blob-reconcile.pp" || failures=$((failures + 1))
if combined_contains "$TMP/blob-warm.ocaml.out" "$TMP/blob-warm.ocaml.err" 'LIFECYCLE-BLOB' ||
   combined_contains "$TMP/blob-warm.lisp.out" "$TMP/blob-warm.lisp.err" 'LIFECYCLE-BLOB'; then
  printf '  blob restore: unexpected body execution\n'
  failures=$((failures + 1))
else
  printf '  blob restore: body skipped\n'
fi
require_tree_digest blob-warm built.bin LIFECYCLE-BYTES || failures=$((failures + 1))
require_store_files blob-warm || failures=$((failures + 1))

# Sandbox confinement is a shared error contract and leaves no escape file.
run_pair sandbox 1 --grant "fs:$WORK:rw" "$SANDBOX_FIXTURE" || failures=$((failures + 1))
if [ -e "$WORK/escape" ]; then
  printf '  sandbox confinement: escape file exists\n'
  failures=$((failures + 1))
else
  printf '  sandbox confinement: no escape file\n'
fi

# GC retains the explicit durable root and emits the same inventory summary.
run_pair gc-seed 0 --grant "fs:__ROOT__:rw" --reconcile __ROOT__ "$FIXTURES/gc.pp" || failures=$((failures + 1))
require_tree_digest gc-seed kept.txt GC-KEEP || failures=$((failures + 1))
run_pair gc 0 gc --gc-keep-epochs 1 --gc-grace-seconds 0 || failures=$((failures + 1))
require_store_files gc || failures=$((failures + 1))

# Local lifecycle services stay strict. Process and transport are boundaries
# only when the OCaml reference cleanly rejects the host operation.
run_local_case 'watch stabilization' 1 --watch --once "$FIXTURES/watch.pp" || failures=$((failures + 1))
run_local_case 'push stabilization' 1 --stabilize "$FIXTURES/watch.pp" || failures=$((failures + 1))
run_local_case 'serial scheduling' 0 --schedule serial "$FIXTURES/schedule.pp" || failures=$((failures + 1))
run_local_case 'parallel scheduling' 0 --schedule parallel:2 "$FIXTURES/schedule.pp" || failures=$((failures + 1))
run_local_case 'race scheduling' 0 --schedule race:2 "$FIXTURES/schedule.pp" || failures=$((failures + 1))
run_local_case 'fenced journal recovery' 0 --grant "fs:__ROOT__:rw" \
  --fenced-policy retry --reconcile __ROOT__ "$FIXTURES/fenced.pp" || failures=$((failures + 1))
run_host_boundary_case 'process reconciliation' 0 \
  'verify-after-write failed|verify-after-write' --grant process \
  --supervise "$FIXTURES/process.pp" || failures=$((failures + 1))
TRANSPORT_HASH=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$TMP/shared/blobs"
printf 'tampered transport bytes' >"$TMP/shared/blobs/$TRANSPORT_HASH"
run_host_boundary_case 'transport tamper rejection' 1 \
  'refusing to accept|corrupt or tampered in transit' --transport-pull blob \
  "$TRANSPORT_HASH" "$TMP/shared" || failures=$((failures + 1))
run_boundary 'remote/network placement' --remote-node token pins root keys reply "$FIXTURES/transport.pp" || failures=$((failures + 1))
run_boundary 'domain reconciliation' --member-name local --reconcile __ROOT__ "$FIXTURES/reconcile.pp" || failures=$((failures + 1))
run_boundary 'island fetch' --fetch-islands "$FIXTURES/network.pp" || failures=$((failures + 1))

if [ "$failures" -ne 0 ]; then
  printf 'lifecycle parity: FAIL (%s checks)\n' "$failures" >&2
  exit 1
fi
printf 'lifecycle parity: OK (reconcile/blob/journal/watch/schedules/transport/sandbox/gc; explicit boundaries)\n'
exit 0
