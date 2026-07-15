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
