#!/usr/bin/env bash
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/stdlib.pp" <<'EOF'
load("stdlib/list.pp")
load("stdlib/string.pp")
load("stdlib/map.pp")
load("stdlib/vector.pp")
load("stdlib/set.pp")
load("stdlib/path.pp")

print(range-by(5, 0, -2))
print(zip(list(1, 2), list(:a, :b)))
print(partition(fn(x) { x < 3 }, list(1, 4, 2)))
print(string-split("a--b-", "--"))
print(lines("a\n\nb\n"))
print(string-replace("a-b-b", "b", "x"))
print(vector->list(vector(4, 5)))
print(list->vector(list(6, 7)))
print(set-has?(list->set(list(:a, :b)), :b))
print(set->list(set-difference(list->set(list(:a, :b)), list->set(list(:b)))))
print(map-to-pairs(map-from-pairs(list(list(:a, 1), list(:b, 2)))))
print(path-dirname("/usr/local/bin"))
print(path-dirname("/usr"))
print(path-normalize("a/./b/../c"))
print(path-join("/tmp", "x"))
print(path-extension("archive.tar.gz"))
print(path-stem("archive.tar.gz"))
print(path-extension(".profile"))
EOF

expected=$'(5 3 1)\n((1 :a) (2 :b))\n{:rest (4), :matched (1 2)}\n("a" "b-")\n("a" "" "b")\n"a-x-x"\n(4 5)\n[6 7]\ntrue\n(:a)\n((:a 1) (:b 2))\n"/usr/local"\n"/"\n"a/c"\n"/tmp/x"\n".gz"\n"archive.tar"\n""'
got=$($PP "$TMP/stdlib.pp" 2>"$TMP/err")
if [ "$got" = "$expected" ]; then ok "stdlib-expansion"; else bad "stdlib-expansion" "expected: $expected" "got: $got" "err: $(cat "$TMP/err")"; fi

cat > "$TMP/errors.pp" <<'EOF'
load("stdlib/list.pp")
range-by(1, 2, 0)
EOF
if $PP "$TMP/errors.pp" >"$TMP/out" 2>"$TMP/err"; then
  bad "stdlib-range-by-zero" "expected failure"
elif grep -q "range-by: step must not be zero" "$TMP/err"; then
  ok "stdlib-range-by-zero"
else
  bad "stdlib-range-by-zero" "err: $(cat "$TMP/err")"
fi

rm -rf "$TMP"
exit "$fail"
