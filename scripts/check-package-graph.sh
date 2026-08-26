#!/usr/bin/env bash
#
# Mechanical package-architecture gate for the pp.rt.* package model.
#
# Checks:
#   1. IN-PACKAGE placement: every file under lisp/runtime/** declares only
#      the packages its entry in the map below admits (dynamic-scope.lisp
#      additionally must start in PP.RT.PROTOCOL and end in PP.RT.SCOPE).
#   2. :use matrix: each pp.rt.* defpackage's :use list in lisp/packages.lisp
#      must match the intended DAG recorded below exactly -- no undeclared
#      edges, no missing required edges.
#   3. Qualified references: `pp.rt.foo:sym` is rejected from any file whose
#      package does not :use pp.rt.foo, unless the (file, target) pair is on
#      the seeded whitelist below; `pp.rt.*::` double-colon references are
#      rejected unconditionally.
#   4. Cycle detection over the pp.rt.* :use graph (DFS); any cycle fails.
#
# Uses only bash/git/sed/awk/grep.

set -uo pipefail

root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd -P)
packages_lisp="$root/lisp/packages.lisp"
[ -f "$packages_lisp" ] || { echo "package-graph: missing $packages_lisp" >&2; exit 1; }

errors=0
fail() {
  printf 'package-graph: %s\n' "$*" >&2
  errors=$((errors + 1))
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/pp-package-graph.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---------------------------------------------------------------------------
# Intended pp.rt.* :use DAG, copied verbatim from lisp/packages.lisp.
# Update this table ONLY when a defpackage :use list changes deliberately.
# ---------------------------------------------------------------------------
intended_use=$(cat <<'EOF'
pp.rt.protocol|
pp.rt.lang|
pp.rt.store|
pp.rt.scope| pp.rt.lang pp.rt.protocol
pp.rt.effects| pp.rt.lang pp.rt.scope pp.rt.protocol
pp.rt.config| pp.rt.lang pp.rt.scope pp.rt.protocol
pp.rt.artifacts| pp.rt.lang pp.rt.store pp.rt.scope pp.rt.protocol
pp.rt.observation| pp.rt.lang pp.rt.store pp.rt.scope pp.rt.artifacts pp.rt.config
pp.rt.cache| pp.rt.lang pp.rt.store pp.rt.observation
pp.rt.eval| pp.rt.lang pp.rt.scope pp.rt.protocol pp.rt.cache
pp.rt.session| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.eval pp.rt.protocol
pp.rt.node| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.cache pp.rt.observation pp.rt.eval pp.rt.session pp.rt.protocol
pp.rt.primitives| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.config pp.rt.observation pp.rt.session pp.rt.eval pp.rt.protocol
pp.rt.journal| pp.rt.store pp.rt.lang
pp.rt.domain| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.eval pp.rt.session pp.rt.node pp.rt.journal pp.rt.protocol
pp.rt.lifecycle.process| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.effects pp.rt.eval pp.rt.session pp.rt.journal pp.rt.domain pp.rt.protocol
pp.rt.fenced| pp.rt.lang pp.rt.scope pp.rt.session pp.rt.journal pp.rt.domain
pp.rt.watch| pp.rt.lang pp.rt.scope pp.rt.store pp.rt.eval pp.rt.session pp.rt.observation pp.rt.domain
pp.rt.executor| pp.rt.session pp.rt.protocol pp.rt.scope
pp.rt.sandbox| pp.rt.lang pp.rt.store pp.rt.scope
pp.rt.island| pp.rt.lang pp.rt.store pp.rt.scope pp.rt.journal pp.rt.observation
pp.rt.distribution| pp.rt.store
pp.rt.lifecycle| pp.rt.lang pp.rt.scope pp.rt.session pp.rt.domain pp.rt.fenced pp.rt.watch pp.rt.executor pp.rt.protocol
EOF
)
printf '%s\n' "$intended_use" > "$tmp/intended"

# DEPENDENCY DEBT — qualified-reference allowances (file basename|target
# package), seeded from every existing occurrence today so the gate starts
# green. These are NOT declared DAG edges: several are reverse dependencies
# (e.g. artifacts->observation, scope->session via call sites, observation
# ->session/domain) that make the source-level graph denser than the :use
# DAG above. Shrink as each reference is converted to a pp.rt.protocol
# generic or a session service; the gate fails on anything not listed.
ref_whitelist=$(cat <<'EOF'
artifacts.lisp|pp.rt.observation
cache.lisp|pp.rt.scope
configuration.lisp|pp.rt.observation
dynamic-scope.lisp|pp.rt.observation
evaluator.lisp|pp.rt.observation
executor.lisp|pp.rt.artifacts
fenced.lisp|pp.rt.journal
fenced.lisp|pp.rt.lifecycle.process
fenced.lisp|pp.rt.session
fenced.lisp|pp.rt.store
island.lisp|pp.rt.store
journal.lisp|pp.rt.session
observations.lisp|pp.rt.domain
observations.lisp|pp.rt.protocol
observations.lisp|pp.rt.session
primitives.lisp|pp.rt.observation
process.lisp|pp.rt.effects
process.lisp|pp.rt.session
process.lisp|pp.rt.store
sandbox.lisp|pp.rt.protocol
sandbox.lisp|pp.rt.store
watch.lisp|pp.rt.observation
watch.lisp|pp.rt.protocol
watch.lisp|pp.rt.store
EOF
)

# ---------------------------------------------------------------------------
# Parse actual (:use ...) lists for every pp.rt.* package.
# Output lines: package|space-separated pp.rt.* targets
# ---------------------------------------------------------------------------
awk '
  /\(defpackage/ { pkg=$2; gsub(/[#:(]/, "", pkg); pend=1; next }
  pend && /\(:use/ {
    line=$0; sub(/.*\(:use/, "", line)
    n=split(line, t, " ")
    out=""
    for(i=1;i<=n;i++){ s=t[i]; gsub(/[#():]/, "", s); if(s ~ /^pp\.rt\./) out=out" "s }
    print pkg "|" out
    pend=0; next
  }
  pend && !/\(:use/ { pend=0 }
' "$packages_lisp" > "$tmp/actual"

use_of() { # use_of <package> <table-file> -> space-separated pp.rt.* targets
  awk -F'|' -v p="$1" '$1 == p { print $2 }' "$2"
}

# --- Check 2: :use matrix --------------------------------------------------
while IFS='|' read -r pkg want; do
  have=$(use_of "$pkg" "$tmp/actual")
  if [ -z "$have" ] && ! grep -q "^${pkg}|" "$tmp/actual"; then
    fail ":use matrix: package ${pkg} is in the intended DAG but has no defpackage in lisp/packages.lisp"
    continue
  fi
  for w in $want; do
    case " $have " in
      *" $w "*) ;;
      *) fail ":use matrix: missing required edge ${pkg} -> ${w}" ;;
    esac
  done
  for h in $have; do
    case " $want " in
      *" $h "*) ;;
      *) fail ":use matrix: undeclared edge ${pkg} -> ${h} (add it to the intended DAG in check-package-graph.sh)" ;;
    esac
  done
done < "$tmp/intended"

# A pp.rt.* package present in packages.lisp but absent from the DAG.
while IFS='|' read -r pkg _; do
  case "$pkg" in pp.rt.*) ;; *) continue ;; esac
  grep -q "^${pkg}|" "$tmp/intended" || \
    fail ":use matrix: undeclared package ${pkg} in lisp/packages.lisp (add its intended :use row to check-package-graph.sh)"
done < "$tmp/actual"

# --- Check 4: cycle detection over the actual pp.rt.* :use graph -----------
awk -F'|' '
  { adj[$1] = adj[$1] " " $2 }
  function dfs(v,    i, c, n, list) {
    if (color[v] == 1) {
      cycle = v
      for (i = depth; i >= 1 && stack[i] != v; i--) cycle = stack[i] " <- " cycle
      printf "cycle detected: %s\n", cycle | "cat 1>&2"
      found = 1
      return
    }
    if (color[v] == 2) return
    color[v] = 1
    stack[++depth] = v
    n = split(adj[v], list, " ")
    for (i = 1; i <= n; i++) {
      c = list[i]
      if (c != "") dfs(c)
    }
    depth--
    color[v] = 2
  }
  END {
    found = 0; depth = 0
    for (p in adj) if (!color[p]) dfs(p)
    exit found ? 1 : 0
  }
' "$tmp/actual" || fail ':use graph: dependency cycle among pp.rt.* packages'

# --- Check 1: IN-PACKAGE placement -----------------------------------------
allowed_in_package() { # allowed_in_package <basename> -> allowed packages
  case "$1" in
    protocol.lisp)     echo 'pp.rt.protocol' ;;
    language.lisp)     echo 'pp.rt.lang' ;;
    primitives.lisp)   echo 'pp.rt.primitives' ;;
    store.lisp)        echo 'pp.rt.store' ;;
    journal.lisp)      echo 'pp.rt.journal' ;;
    dynamic-scope.lisp) echo 'pp.rt.protocol pp.rt.scope' ;;
    effects.lisp)      echo 'pp.rt.effects' ;;
    configuration.lisp) echo 'pp.rt.config' ;;
    artifacts.lisp)    echo 'pp.rt.artifacts' ;;
    observations.lisp) echo 'pp.rt.observation' ;;
    cache.lisp)        echo 'pp.rt.cache' ;;
    state.lisp)        echo 'pp.rt.eval' ;;
    evaluator.lisp)    echo 'pp.rt.eval' ;;
    session.lisp)      echo 'pp.rt.session' ;;
    nodes.lisp)        echo 'pp.rt.node' ;;
    distribution.lisp) echo 'pp.rt.distribution' ;;
    # pp.runtime is a seeded exception: the file still lives there today.
    domains.lisp)      echo 'pp.rt.domain' ;;
    process.lisp)      echo 'pp.rt.lifecycle.process' ;;
    fenced.lisp)       echo 'pp.rt.fenced' ;;
    watch.lisp)        echo 'pp.rt.watch' ;;
    executor.lisp)     echo 'pp.rt.executor' ;;
    sandbox.lisp)      echo 'pp.rt.sandbox' ;;
    island.lisp)       echo 'pp.rt.island' ;;
    lifecycle.lisp)    echo 'pp.rt.lifecycle' ;;
    *)                 echo '' ;;
  esac
}

in_packages_of() { # ordered, deduplicated in-package declarations of a file
  grep -oE '\(in-package[[:space:]]*#?:?[A-Za-z0-9.-]+' "$1" 2>/dev/null |
    sed 's/.*[#:]//' | awk '!seen[$0]++'
}

runtime_files=$(cd "$root" && find lisp/runtime -name '*.lisp' | LC_ALL=C sort)
[ -n "$runtime_files" ] || fail 'no lisp/runtime files found'

for f in $runtime_files; do
  rel=${f#"$root"/}
  base=${rel##*/}
  allowed=$(allowed_in_package "$base")

  # Check 3 inputs: the union of :use over every package the file enters,
  # plus those packages themselves (self-qualified references are legal).
  permitted=""
  for p in $(in_packages_of "$f"); do
    permitted="$permitted $p $(use_of "$p" "$tmp/intended")"
  done

  if [ -z "$allowed" ]; then
    fail "in-package: ${rel}: unknown runtime file; add an entry to the package map in check-package-graph.sh"
    continue
  fi

  first_pkg=$(in_packages_of "$f" | sed -n '1p')
  last_pkg=$(in_packages_of "$f" | sed -n '$p')

  if [ "$base" = 'dynamic-scope.lisp' ]; then
    [ "$first_pkg" = 'pp.rt.protocol' ] || \
      fail "in-package: ${rel}: first in-package is ${first_pkg:-<none>}, must be pp.rt.protocol (frame structs live at top)"
    [ "$last_pkg" = 'pp.rt.scope' ] || \
      fail "in-package: ${rel}: last in-package is ${last_pkg:-<none>}, must be pp.rt.scope"
  else
    [ -n "$first_pkg" ] || fail "in-package: ${rel}: no (in-package ...) form"
  fi

  for p in $(in_packages_of "$f"); do
    case " $allowed " in
      *" $p "*) ;;
      *) fail "in-package: ${rel}: not allowed to declare (in-package #$p); allowed: $allowed" ;;
    esac
  done

  # --- Check 3a: unconditional ban on pp.rt.*:: double-colon references ----
  while IFS= read -r target; do
    fail "qualified reference: ${rel}: '$target...' bypasses the package boundary; export the symbol and use single colon"
  done < <(grep -Eo 'pp\.rt\.[A-Za-z0-9.-]+::' "$f" 2>/dev/null | sort -u)

  # --- Check 3b: pp.rt.X:sym requires a declared :use edge or whitelist ----
  while IFS= read -r target; do
    [ -n "$target" ] || continue
    case " $permitted " in
      *" $target "*) continue ;;
    esac
    if printf '%s\n' "$ref_whitelist" | grep -Fxq "${base}|${target}"; then
      continue
    fi
    fail "qualified reference: ${rel}: pp.rt.${target#pp.rt.}:... without :use edge (declare the edge in both defpackages and the DAG table, or stop referencing it)"
  done < <(grep -Eo 'pp\.rt\.[A-Za-z0-9.-]+:[^:]' "$f" 2>/dev/null | sed 's/:.$//' | sort -u)
done

if [ "$errors" -eq 0 ]; then
  echo 'Package graph checks: all passed'
fi
exit "$errors"
