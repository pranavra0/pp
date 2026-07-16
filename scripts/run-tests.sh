#!/usr/bin/env bash
# Differential test suite. Runs every tests/NNN-*.pp under BOTH backends
# (tree-walker and bytecode VM) and diffs their output — any divergence is a
# failure — then runs every tests/*.sh oracle. Invoked by `dune runtest`; can
# also be run by hand from the repo root:
#
#     dune build && scripts/run-tests.sh ./pp
#
# Arg 1 is the pp binary (default: the dune-built one). The tests run with the
# repo root as cwd so `(load "stdlib/list.pp")` resolves.
#
# Cases run CONCURRENTLY: each is an independent job (own store under a
# throwaway HOME, own scratch files) so a bounded fan-out is safe, and wall
# time collapses to roughly the slowest single case rather than their sum.
# TEST_JOBS caps the fan-out (default: online CPUs); TEST_JOBS=1 forces the
# old serial order when debugging a flake. Each job's output is buffered and
# replayed in enumeration order, so a parallel run reads identically to a
# serial one.
#
# Adding a shell oracle is just: create tests/NNN-name.sh (it is picked up by
# the glob below; its second line is shown as the description). Adding a
# differential case is: create tests/NNN-name.pp. Neither touches this file.
set -uo pipefail

# ---- Worker: run ONE job, printing its verdict on the first line (PASS or
# FAIL) followed by the human-readable block the aggregator replays. This is
# the same script re-invoked (see the xargs fan-out below); PP and FUZZ arrive
# through the environment the parent exported.
if [ "${1:-}" = "--worker" ]; then
  IFS='|' read -r kind file <<<"$2"
  scratch=$(mktemp -d)
  trap 'rm -rf "$scratch"' EXIT
  case "$kind" in
    pp)
      "$PP" --bytecode "$file" >"$scratch/bc" 2>&1
      "$PP"             "$file" >"$scratch/tw" 2>&1
      if diff -u "$scratch/tw" "$scratch/bc" >"$scratch/diff"; then
        printf 'PASS\nok   %s\n' "$file"
      else
        printf 'FAIL\nFAIL %s  (backends disagree)\n' "$file"
        cat "$scratch/diff"
      fi ;;
    sh)
      name=$(basename "$file" .sh)
      desc=$(sed -n '2s/^#[[:space:]]*//p' "$file")
      if bash "$file" >"$scratch/out" 2>&1; then verdict=PASS; endline="ok   $name"
      else verdict=FAIL; endline="FAIL $name"; fi
      printf '%s\n--- %s — %s ---\n' "$verdict" "$name" "$desc"
      cat "$scratch/out"
      printf '%s\n' "$endline" ;;
  esac
  exit 0
fi

PP="${1:-_build/default/src/main.exe}"
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
export PP
export FUZZ="${FUZZ:-tools/fuzz.exe}"
SELF="$0"

# ---- Enumerate jobs: differential .pp cases first, then shell oracles, so the
# replay order below matches the historical serial run.
jobs=()
for f in tests/[0-9]*.pp; do jobs+=("pp|$f"); done
for f in tests/*.sh; do
  [ "$(basename "$f")" = "lib.sh" ] && continue
  jobs+=("sh|$f")
done
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
printf '%s\n' "${tagged[@]}" |
  xargs -P "$JOBS" -I{} bash -c '
    line="$1"; idx="${line%%|*}"; spec="${line#*|}"
    "$0" --worker "$spec" >"$RESULTS/$idx.out" 2>&1
  ' "$SELF" "{}"

# ---- Replay results in enumeration order; a leading FAIL line flips the exit
# code.
fail=0
for i in $(seq 0 $((n - 1))); do
  out="$RESULTS/$(printf '%03d' "$i").out"
  [ -f "$out" ] || { echo "FAIL job $i produced no output"; fail=1; continue; }
  [ "$(sed -n '1p' "$out")" = "FAIL" ] && fail=1
  sed '1d' "$out"
done

exit $fail
