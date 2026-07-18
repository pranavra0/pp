#!/usr/bin/env bash
# Phase-1 exit criterion 6: pp builds itself via a build.pp.
#
# The dune invocation is ONE node keyed on the coarse `tree:src` cell — so a
# null rebuild is a cache hit and dune is never executed (the journal proves
# it), while any change under src/ re-runs the build. Whole-project
# granularity: pp orchestrates its own build; per-file OCaml compilation
# stays dune's job.
#
# Run from the repo root, OUTSIDE `dune runtest` (dune cannot nest).
# Uses an isolated HOME so the developer's real store is untouched.
set -uo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"
PP=${PP:-"$REPO/_build/default/src/app/main.exe"}

TMP=$(mktemp -d)
REAL_HOME="$HOME"      # opam needs ~/.opam; only pp's store is isolated
export HOME="$TMP"
OUT="$TMP/out"
J="$TMP/.pp/store/journal/log"
fail=0

execs() { grep -c "^exec " "$J" 2>/dev/null; true; }

cat > "$TMP/build-self.pp" <<EOF
let (pp-bin = force(node {
  perform log("DUNE-BUILD")
  do {
    perform run("sh", "-c", "out=\$(pwd); cd $REPO && HOME=$REAL_HOME opam exec -- dune build 2>&1 && cp _build/default/src/app/main.exe \"\$out/pp.bin\"")
    blob(slurp("pp.bin"))
  }
})) { map-insert({}, "pp", string-append(pp-bin, ":x")) }
EOF

G=(--grant "fs:$REPO/src:ro" --grant "fs:$OUT:wo" --grant process)

echo "-- run 1: cold (dune runs once)"
"$PP" "${G[@]}" --reconcile "$OUT" "$TMP/build-self.pp" 2>&1 | tail -2
e1=$(execs)
if [ "$e1" -eq 1 ] && [ -x "$OUT/pp" ] && "$OUT/pp" --version >/dev/null; then
  echo "ok   self-build: dune ran once, $OUT/pp is a working pp"
else
  echo "FAIL self-build: execs=$e1"; fail=1
fi

echo "-- run 2: null rebuild (dune must NOT run)"
"$PP" "${G[@]}" --reconcile "$OUT" "$TMP/build-self.pp" 2>&1 | tail -1
e2=$(execs)
if [ "$e2" -eq "$e1" ]; then
  echo "ok   self-null: zero processes (journal: $e2 execs total)"
else
  echo "FAIL self-null: $((e2 - e1)) new execs"; fail=1
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== SELF-BUILD (criterion 6) PASSED ==="; fi
exit $fail
