#!/usr/bin/env bash
# Public command parsing and startup failures use one deterministic error channel.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
assert_grep() {
  local name="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then ok "$name"
  else bad "$name" "expected $pattern in $file: $(cat "$file")"; fi
}
assert_not_grep() {
  local name="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file"; then
    bad "$name" "did not expect $pattern in $file: $(cat "$file")"
  else ok "$name"; fi
}


run_status() {
  local name="$1" expected="$2"
  shift 2
  "$@" >"$TMP/$name.out" 2>&1
  local status=$?
  if [ "$status" -eq "$expected" ]; then ok "$name-status"
  else bad "$name-status" "expected $expected, got $status: $(cat "$TMP/$name.out")"; fi
}

run_status help-no-home 0 env -u HOME "$PP" --help
assert_grep help-no-home-output 'Usage:' "$TMP/help-no-home.out"
run_status version-no-home 0 env -u HOME "$PP" --version
assert_grep version-no-home-output '^pp v' "$TMP/version-no-home.out"
run_status help-empty-home 0 env HOME= "$PP" --help
assert_grep help-empty-home-output 'Usage:' "$TMP/help-empty-home.out"
run_status version-empty-home 0 env HOME= "$PP" --version
assert_grep version-empty-home-output '^pp v' "$TMP/version-empty-home.out"

run_status eval-no-home 1 env -u HOME "$PP" -e '1'
assert_grep eval-no-home-structured '^pp: error: HOME is not set$' "$TMP/eval-no-home.out"
assert_not_grep eval-no-home-not-raw 'Fatal error|exception Not_found' "$TMP/eval-no-home.out"

run_status unknown-option 1 "$PP" --definitely-not-a-flag
assert_grep unknown-option-message '^pp: error: unrecognized option: --definitely-not-a-flag$' "$TMP/unknown-option.out"

run_status conflicting-modes 1 "$PP" --version gc
assert_grep conflicting-modes-message '^pp: error: conflicting command modes:' "$TMP/conflicting-modes.out"

run_status remote-node-no-source 1 "$PP" --remote-node token pins shared keys reply
assert_grep remote-node-no-source-message '^pp: error: --remote-node requires a source file$' "$TMP/remote-node-no-source.out"
assert_not_grep remote-node-no-source-not-raw 'Fatal error|Exception|Internal error' "$TMP/remote-node-no-source.out"

run_status remote-node-desired-object 1 "$PP" --remote-node token pins shared keys reply \
  --desired-object deadbeef shared source.pp
assert_grep remote-node-desired-object-message '^pp: error: --desired-object cannot be combined with a program$' "$TMP/remote-node-desired-object.out"
assert_not_grep remote-node-desired-object-not-raw 'Fatal error|Exception|Internal error' "$TMP/remote-node-desired-object.out"

run_status desired-object-no-target 1 "$PP" --desired-object deadbeef shared
assert_grep desired-object-no-target-message '^pp: error: --desired-object requires --reconcile or --supervise$' "$TMP/desired-object-no-target.out"
assert_not_grep desired-object-no-target-not-raw 'Fatal error|Exception|Internal error' "$TMP/desired-object-no-target.out"

run_status remote-node-admin-mode 1 "$PP" --remote-node token pins shared keys reply cluster-init
assert_grep remote-node-admin-mode-message '^pp: error: conflicting command modes:' "$TMP/remote-node-admin-mode.out"
assert_not_grep remote-node-admin-mode-not-raw 'Fatal error|Exception|Internal error' "$TMP/remote-node-admin-mode.out"

run_status conflicting-frontends 1 "$PP" --emit-braces a --roundtrip-braces b
assert_grep conflicting-frontends-message '^pp: error: conflicting command modes:' "$TMP/conflicting-frontends.out"

run_status once-watch 1 "$PP" --once --watch program.pp
assert_grep once-watch-message '^pp: error: --once cannot be combined with --watch$' "$TMP/once-watch.out"
run_status once-no-source 1 "$PP" --once
assert_grep once-no-source-message '^pp: error: --once requires a source file$' "$TMP/once-no-source.out"
assert_not_grep once-no-source-not-raw 'Fatal error|Exception|Internal error' "$TMP/once-no-source.out"


run_status short-help 0 env -u HOME "$PP" -h
assert_grep short-help-output 'Usage:' "$TMP/short-help.out"

if [ "$fail" -eq 0 ]; then echo "=== CLI BOUNDARIES TEST PASSED ==="; fi
exit "$fail"
