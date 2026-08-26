#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
[ -f "$root/lisp/pp.asd" ] || { echo "architecture: missing lisp/pp.asd" >&2; exit 1; }
[ -f "$root/lisp/packages.lisp" ] || { echo "architecture: missing lisp/packages.lisp" >&2; exit 1; }
[ -f "$root/lisp/app/main.lisp" ] || { echo "architecture: missing lisp/app/main.lisp" >&2; exit 1; }
[ -x "$root/scripts/build-lisp.sh" ] || { echo "architecture: build-lisp.sh is not executable" >&2; exit 1; }

fail() {
  printf '%s\n' "Architecture checks: $1" >&2
  exit 1
}

check_absent() {
  local pattern="$1" label="$2"
  if grep -R -nE --exclude='*.md' "$pattern" "$root/lisp" >/dev/null; then
    fail "$label"
  fi
}

grep -R -nE --include='*.lisp' 'pp\.(runtime|app)' "$root/lisp/kernel" >/dev/null &&
  fail 'kernel depends on runtime/app'
grep -R -nE --include='*.lisp' 'pp\.app' "$root/lisp/frontend" >/dev/null &&
  fail 'frontend depends on app'
grep -R -nE --include='*.lisp' 'pp\.app' "$root/lisp/runtime" >/dev/null &&
  fail 'runtime depends on app'
if grep -R -nE --include='domains.lisp' \
     'trace-repository-put|runtime-cache-lookup|runtime-node-key' \
     "$root/lisp/runtime/lifecycle" >/dev/null; then
  fail 'lifecycle domain planning owns node/cache persistence'
fi
if grep -nE 'runtime-evaluator-state-persistent-cache|defun[[:space:]]+runtime-evaluator-node-key' \
       "$root/lisp/runtime/evaluator.lisp" >/dev/null; then
  fail 'evaluator owns node identity/cache internals'
fi
check_absent '\*runtime-macro-contexts\*' 'process-global macro context registry'
check_absent 'runtime-evaluator-state-(capabilities|config-stack|handler-stack)' \
  'evaluator dynamic-state mirror'

sandbox=$(mktemp -d "${TMPDIR:-/tmp}/pp-architecture.XXXXXX")
trap 'rm -rf "$sandbox"' EXIT
"$root/scripts/build-lisp.sh" --output "$sandbox/pp" >/dev/null
HOME="$sandbox/home" "$sandbox/pp" --version >/dev/null
HOME="$sandbox/home" "$sandbox/pp" -e '1 + 2' >/dev/null
check_absent 'runtime-evaluator-state-node-force-function' \
  'evaluator node-force callback seam (use the session :node-force service)'
check_absent 'runtime-evaluator-state-perform-function' \
  'evaluator effect callback mirror (use the dynamic dispatcher)'
check_absent 'runtime-thunk-content-hash|runtime-thunk-make-with-hash' \
  'persistent thunk alternate identity outside the Node Engine'
if git -C "$root" ls-files '*.fasl' 2>/dev/null | grep -q .; then
  fail 'compiled fasl artifacts are tracked beside source'
fi
if [ -e "$root/lisp/runtime/thunks" ]; then
  fail 'legacy thunks module still present'
fi
"$root/scripts/check-package-graph.sh"
printf '%s\n' 'Architecture checks: all passed'
