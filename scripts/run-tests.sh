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
# Adding a shell oracle is now just: create tests/NNN-name.sh (it is picked up
# by the glob below; its second line is shown as the description). Adding a
# differential case is: create tests/NNN-name.pp. Neither touches this file.
set -uo pipefail
PP="${1:-_build/default/src/main.exe}"
export PP
export FUZZ="${FUZZ:-tools/fuzz.exe}"
fail=0

# ---- Differential suite: every .pp under both backends ----
for f in tests/[0-9]*.pp; do
  "$PP" --bytecode "$f" > /tmp/pp-bc.out 2>&1
  "$PP"             "$f" > /tmp/pp-tw.out 2>&1
  if diff -u /tmp/pp-tw.out /tmp/pp-bc.out > /tmp/pp-diff.out; then
    echo "ok   $f"
  else
    echo "FAIL $f  (backends disagree)"
    cat /tmp/pp-diff.out
    fail=1
  fi
done

# ---- Shell oracles: every tests/*.sh except the sourced library ----
# Each script isolates its own store (mktemp + HOME override) and reports its
# own ok/FAIL assertion lines; here we only announce it, honor its exit code,
# and print one summary line. The description is the script's second line.
for f in tests/*.sh; do
  base=$(basename "$f")
  [ "$base" = "lib.sh" ] && continue
  name=${base%.sh}
  desc=$(sed -n '2s/^#[[:space:]]*//p' "$f")
  echo "--- $name — $desc ---"
  if bash "$f"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fail=1
  fi
done

exit $fail
