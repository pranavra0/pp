# Shared preamble for the tests/*.sh oracles. Source it right after
# `set -uo pipefail`:
#
#     . "$(dirname "$0")/lib.sh"
#
# It resolves the pp binary to an absolute path (so HOME-isolated runs that
# move cwd still find it), isolates the store under a throwaway HOME, and
# provides the ok/bad assertion helpers plus the `fail` accumulator that the
# script's trailing `exit $fail` reports. A script that drives several hosts
# just overrides HOME per invocation; the export here is the fallback.
#
# `assert` stays per-script: its shape differs by suite.
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# ---- Wait for a condition, never a fixed sleep ----
#
# Watch/stabilize/schedule oracles observe events that land asynchronously (a
# poll iteration re-runs, a spawned process writes its status file). Blocking
# on a flat `sleep N` picked to out-wait the worst case is both slow (it pays
# the worst case every run) and flaky (the worst case is unbounded). These
# helpers proceed the instant the event holds and only give up after a bound,
# so a passing run is as fast as the machine allows and a real hang still
# fails rather than hanging forever.

# Poll CMD (bounded) until it succeeds; return its final status. The bound is
# in seconds, sampled every 100 ms.
wait_for() {  # TIMEOUT-SECS CMD [ARGS...]
  local secs="$1"; shift
  local i=0 max=$(( secs * 10 ))
  while [ "$i" -lt "$max" ]; do
    "$@" 2>/dev/null && return 0
    sleep 0.1; i=$(( i + 1 ))
  done
  "$@" 2>/dev/null
}

# Poll until PAT occurs exactly WANT times in FILE, then assert exactness.
# Replaces `sleep N; assert_count`: it waits for the count to ARRIVE instead
# of guessing how long the event takes, and fails (naming the shortfall) if it
# never does. grep -c exits 1 printing "0" on no match, so the `|| printf 0`
# fallback would double the line — hence the ${n:-0} guard.
assert_count() {  # NAME PAT WANT FILE [TIMEOUT-SECS=10]
  local name="$1" pat="$2" want="$3" file="$4" secs="${5:-10}"
  local i=0 max=$(( secs * 10 )) got=0
  while [ "$i" -lt "$max" ]; do
    got=$(grep -cE "$pat" "$file" 2>/dev/null); got=${got:-0}
    [ "$got" = "$want" ] && break
    sleep 0.1; i=$(( i + 1 ))
  done
  if [ "$got" = "$want" ]; then ok "$name"
  else bad "$name" "expected $pat count $want, got $got" "--- $file ---" "$(cat "$file" 2>/dev/null)"; fi
}

assert_count_stable() {  # NAME PAT WANT FILE [TIMEOUT-SECS=1]
  local name="$1" pat="$2" want="$3" file="$4" secs="${5:-1}"
  local i=0 max=$(( secs * 10 )) got=0
  while [ "$i" -lt "$max" ]; do
    got=$(grep -cE "$pat" "$file" 2>/dev/null); got=${got:-0}
    if [ "$got" -ne "$want" ]; then
      bad "$name" "expected stable count $want, got $got" "--- $file ---" "$(cat "$file" 2>/dev/null)"
      return
    fi
    sleep 0.1
    i=$(( i + 1 ))
  done
  ok "$name"
}

# Explicit lifecycle vocabulary for integration tests. A command creates a
# process; an evaluation is one cold, one-shot run; a watch pass is observed
# by waiting for its output; and a REPL input is one logical submitted form.
new_command() { "$PP" "$@"; }
new_evaluation() { new_command --once "$@"; }
new_watch_pass() {  # NAME PATTERN COUNT FILE [TIMEOUT-SECS]
  assert_count "$@"
}
repl_input() {  # logical input lines; one command, many REPL inputs
  printf '%s\n' "$@" | new_command
}
