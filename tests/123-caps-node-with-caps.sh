#!/usr/bin/env bash
# Integration regression: a persistent node body executes `with-caps` while
# OUTER capability frames are installed.
#
#   ambient: fs:$T/d:ro            (session grant)
#   with-caps(ro-a) {              <- evaluator :caps-enter frame
#     force(node { ... })          <- node pushes/restores captured caps
#     slurp("$T/d/b/g")            <- AMBIENT grant; needs lower frames
#   }
#
# (Node bodies are scripting-tier and reject capability free variables, so
# the innermost with-caps runs just outside the node boundary; the frame
# destruction being regression-tested happens in the evaluator transitions
# around the node force itself.)
#
# The old whole-stack setter collapsed {ro-b, ro-a, captured, ambient} to a
# single frame at every transition, so after the node force the ro-a frame
# was gone and the post-force read failed with a capability error. The
# frame-replacing operation keeps outer frames intact.
set -uo pipefail

PP=${PP:-bin/pp}
TMP=$(mktemp -d)
fail=0
assert() { local n="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then echo "ok   $n"
  else echo "FAIL $n: expected '$pat' $mode in $file, got $got"
       echo "--- output ---"; cat "$file"; fail=1; fi; }

mkdir -p "$TMP/d/a" "$TMP/d/b"
printf 'A\n' > "$TMP/d/a/f.txt"
printf 'B\n' > "$TMP/d/b/g.txt"

{ echo "with-caps(cap-restrict(current-capabilities(), \"$TMP/d/a\", :ro)) {"
  echo "  print(force(node { slurp(\"$TMP/d/a/f.txt\") }))"
  echo "}"
  echo "print(slurp(\"$TMP/d/b/g.txt\"))"
} > "$TMP/prog.pp"} > "$TMP/prog.pp"

timeout -k 5 30 "$PP" --grant "fs:$TMP/d/a:ro" --grant "fs:$TMP/d/b:ro" \
  "$TMP/prog.pp" > "$TMP/out" 2>&1 || true

assert "node-body-caps-read" '"B' present
assert "ro-a-frame-survives-force" '"A' present
assert "ambient-frame-survives-all" '"B' present
assert "no-capability-error" "capability" absent

rm -rf "$TMP"
exit $fail
