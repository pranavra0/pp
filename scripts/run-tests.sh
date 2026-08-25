#!/usr/bin/env bash
# Single-engine test suite. For tests/NNN-*.pp cases, runs the Lisp image once
# under an isolated HOME, diffs against a committed .expected file (stdout+stderr
# and final exit-code line), and fails on any difference. For tests/*.sh oracles,
# runs the script and checks its exit status.
#
# Arg 1 is the pp binary (default: bin/pp). The tests run with the repo root as
# cwd so `(load "stdlib/list.pp")` resolves.
#
# Cases run CONCURRENTLY: each is an independent job (own store under a
# throwaway HOME, own scratch files) so a bounded fan-out is safe, and wall
# time collapses to roughly the slowest single case rather than their sum.
# TEST_JOBS caps the fan-out (default: online CPUs); TEST_JOBS=1 forces the
# old serial order when debugging a flake. Each job's output is buffered and
# replayed in enumeration order, so a parallel run reads identically to a
# serial one.
#
# Adding a .pp expected-output oracle: create tests/NNN-name.pp, bless its
# .expected with `scripts/run-tests.sh` (a missing .expected fails with a
# message). Add a shell oracle: create tests/NNN-name.sh.
set -uo pipefail

# ---- Worker: run ONE job, printing its verdict on the first line (PASS or
# FAIL) followed by the human-readable block the aggregator replays. This is
# the same script re-invoked (see the xargs fan-out below); PP arrives through
# the environment the parent exported.
if [ "${1:-}" = "--worker" ]; then
  IFS='|' read -r kind file <<<"$2"
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  run_bounded() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
      # -k backs TERM with SIGKILL: a process wedged in an uninterruptible
      # syscall ignores TERM, and the watchdog must still fire.
      timeout -k 5 "$seconds" "$@"
    elif command -v perl >/dev/null 2>&1; then
      perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
    else
      "$@" &
      child=$!
      ( sleep "$seconds"; kill -TERM "$child" 2>/dev/null || exit 0; sleep 1; kill -KILL "$child" 2>/dev/null || true ) &
      watchdog=$!
      wait "$child"; status=$?
      kill "$watchdog" 2>/dev/null || true
      wait "$watchdog" 2>/dev/null || true
      return "$status"
    fi
  }
  case "$kind" in
    pp)
      scratch_home=$(mktemp -d)
      export HOME="$scratch_home"
      run_bounded "${TEST_CASE_TIMEOUT:-120}" "$PP" "$file" >"$scratch/actual" 2>&1
      ec=$?
      printf '# exit: %d\n' "$ec" >> "$scratch/actual"
      expected="${file}.expected"
      if [ ! -f "$expected" ]; then
        printf 'FAIL\nFAIL %s  (no .expected file — bless with:\n' "$file"
        printf '  TMP=$$(mktemp -d) HOME=$$TMP bin/pp %s >$$TMP/out 2>&1; ec=$$?; { cat $$TMP/out; printf "\\n# exit: %%d\\n" $$ec; } >%s)\n' "$file" "$expected"
      elif diff -u "$expected" "$scratch/actual" >"$scratch/diff"; then
        printf 'PASS\nok   %s\n' "$file"
      else
        printf 'FAIL\nFAIL %s  (output differs from expected)\n' "$file"
        cat "$scratch/diff"
      fi
      rm -rf "$scratch_home" ;;
    sh)
      name=$(basename "$file" .sh)
      desc=$(sed -n '2s/^#[[:space:]]*//p' "$file")
      if run_bounded "${SH_CASE_TIMEOUT:-300}" bash "$file" >"$scratch/out" 2>&1; then verdict=PASS; endline="ok   $name"
      else verdict=FAIL; endline="FAIL $name"; fi
      printf '%s\n--- %s — %s ---\n' "$verdict" "$name" "$desc"
      cat "$scratch/out"
      printf '%s\n' "$endline" ;;
  esac
  exit 0
fi

PP="${1:-bin/pp}"
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
export PP
SELF="$0"

# ---- Enumerate jobs: .pp expected-output cases first, then shell oracles, so the
# replay order below matches the historical serial run.
jobs=()
for f in tests/[0-9]*.pp; do jobs+=("pp|$f"); done
for f in tests/*.sh; do
  [ "$(basename "$f")" = "lib.sh" ] && continue
  jobs+=("sh|$f")
done
# ---- Optional static shard: TEST_SHARD="i/n" keeps only cases whose
# enumeration index satisfies i' % n == i, so callers can spread the suite
# across several runners while every case still runs exactly once. Round-robin
# (not contiguous blocks) keeps each shard's mix of heavy and light cases even.
if [ -n "${TEST_SHARD:-}" ]; then
  IFS=/ read -r shard_index shard_count <<<"$TEST_SHARD"
  filtered=()
  for i in "${!jobs[@]}"; do
    [ $(( i % shard_count )) -eq "$shard_index" ] && filtered+=("${jobs[$i]}")
  done
  jobs=("${filtered[@]}")
fi

n=${#jobs[@]}

RESULTS=$(mktemp -d)
export RESULTS
trap 'rm -rf "$RESULTS"' EXIT

JOBS="${TEST_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

# Fan out: tag each job with a zero-padded index (stable result-file name),
# then run up to $JOBS workers at once. Each writes its verdict+block to its
# own file under $RESULTS.
tagged=()
for i in "${!jobs[@]}"; do tagged+=("$(printf '%03d' "$i")|${jobs[$i]}"); done
if [ "$JOBS" -eq 1 ]; then
  for line in "${tagged[@]}"; do
    idx="${line%%|*}"; spec="${line#*|}"
    printf 'running test %s\n' "$spec" >&2
    "$SELF" --worker "$spec" >"$RESULTS/$idx.out" 2>&1
  done
else
  printf '%s\n' "${tagged[@]}" |
    xargs -P "$JOBS" -I{} bash -c '
      line="$1"; idx="${line%%|*}"; spec="${line#*|}"
      # Live timeline on stderr: a wedged case names itself in the CI log
      # (result files are only replayed after the whole fan-out finishes).
      printf "[%s] start %s\n" "$(date -u +%T)" "$spec" >&2
      "$0" --worker "$spec" >"$RESULTS/$idx.out" 2>&1
      printf "[%s] done   %s\n" "$(date -u +%T)" "$spec" >&2
    ' "$SELF" "{}"
fi

# ---- Replay results in enumeration order; a leading FAIL line flips the exit
# code.
fail=0
for i in $(seq 0 $((n - 1))); do
  out="$RESULTS/$(printf '%03d' "$i").out"
  [ -f "$out" ] || { echo "FAIL job $i produced no output"; fail=1; continue; }
  [ "$(sed -n '1p' "$out")" = "FAIL" ] && fail=1
  sed '1d' "$out"
done

bash scripts/test-categories.sh

exit $fail
