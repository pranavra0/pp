#!/usr/bin/env bash
# Real-world proof: build Lua 5.4.7 with a
# real build.pp (run-dep nodes + blobs + reconcile), then show:
#   - null rebuild: zero processes (journal), fast;
#   - comment-only edit to a core header: every dependent TU recompiles,
#     the link is cut off (byte-identical objects ⇒ link node hits);
#   - rm -rf build/: restored from the store with zero compiler re-runs,
#     binary byte-identical and still runs Lua code.
#
# Downloads lua.org's tarball on first use (cached in scripts/.cache).
# Run from the repo root, outside dune. Isolated HOME.
set -uo pipefail
cd "$(dirname "$0")/.."
PP=${PP:-"$PWD/_build/default/src/main.exe"}
command -v cc >/dev/null || { echo "SKIPPED (no cc)"; exit 0; }

CACHE="$PWD/scripts/.cache"
mkdir -p "$CACHE"
TARBALL="$CACHE/lua-5.4.7.tar.gz"
if [ ! -f "$TARBALL" ]; then
  echo "-- fetching lua-5.4.7.tar.gz"
  curl -sf -o "$TARBALL" https://www.lua.org/ftp/lua-5.4.7.tar.gz || {
    echo "SKIPPED (no network)"; exit 0; }
fi

TMP=$(mktemp -d)
export HOME="$TMP"
tar -xzf "$TARBALL" -C "$TMP"
SRC="$TMP/lua-5.4.7/src"
BUILD="$TMP/build"
J="$TMP/.pp/store/journal/log"
fail=0

execs() { grep -c "^exec " "$J" 2>/dev/null; true; }
links() { grep -c "cc -o lua " "$J" 2>/dev/null; true; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time()*1000'; }

# Manifest: every .c except luac.c (its own main) and onelua.c (amalgam).
( cd "$SRC" && ls *.c | sed 's/\.c$//' | grep -vE '^(luac|onelua)$' ) > "$SRC/sources.txt"
TU=$(wc -l < "$SRC/sources.txt" | tr -d ' ')
echo "-- $TU translation units"

cat > "$TMP/build.pp" <<EOF
(def (map2 f lst) (if (nil? lst) nil (cons (f (car lst)) (map2 f (cdr lst)))))
(def (each f lst) (if (nil? lst) nil (do (f (car lst)) (each f (cdr lst)))))
(def (foldl2 f acc lst) (if (nil? lst) acc (foldl2 f (f acc (car lst)) (cdr lst))))

(def (compile name)
  (force (node
    (do (perform run-dep (string-append name ".d")
          "cc" "-MD" "-MF" (string-append name ".d") "-O2" "-c"
          (string-append "$SRC/" (string-append name ".c"))
          "-o" (string-append name ".o"))
        (blob (slurp (string-append name ".o")))))))

(def (link objs)
  (force (node
    (do (each (fn (o) (perform write-file (string-append (car o) ".o")
                        (blob-get (cdr o)))) objs)
        (do (perform write-file "link.d" "lua: ")
            (do (perform run-dep "link.d" "sh" "-c"
                  (string-append "cc -o lua "
                    (string-append
                      (foldl2 (fn (acc o) (string-append acc (string-append (car o) ".o ")))
                              "" objs)
                      "-lm")))
                (blob (slurp "lua"))))))))

(let [names (string-split (slurp "$SRC/sources.txt") "\n")]
  (let [objs (force-deep (map2 (fn (n) (cons n (compile n))) names))]
    (let [lua (link objs)]
      (foldl2 (fn (m o) (map-insert m (string-append (car o) ".o") (cdr o)))
              (map-insert (hash-map) "lua" (string-append lua ":x"))
              objs))))
EOF

G=(--grant "fs:$SRC:ro" --grant "fs:$BUILD:wo" --grant process)
run() { "$PP" "${G[@]}" --reconcile "$BUILD" "$TMP/build.pp" > "$TMP/out" 2>&1; }

echo "-- cold build"
t0=$(now_ms); run; t1=$(now_ms)
e0=$(execs)
if [ "$e0" -eq $((TU + 1)) ] && [ -x "$BUILD/lua" ]; then
  echo "ok   lua-cold: $TU compiles + 1 link in $((t1 - t0))ms"
else
  echo "FAIL lua-cold: execs=$e0"; tail -5 "$TMP/out"; fail=1
fi
v=$("$BUILD/lua" -e 'print(_VERSION)')
if [ "$v" = "Lua 5.4" ]; then echo "ok   lua-runs ($v)"
else echo "FAIL lua-runs: '$v'"; fail=1; fi
cp "$BUILD/lua" "$TMP/lua.saved"

echo "-- null rebuild"
t0=$(now_ms); run; t1=$(now_ms)
e1=$(execs)
if [ "$e1" -eq "$e0" ]; then echo "ok   lua-null: zero processes ($((t1 - t0))ms)"
else echo "FAIL lua-null: $((e1 - e0)) new execs"; fail=1; fi

echo "-- comment-only edit to lua.h (the core header)"
printf '\n/* phase-1 exit: comment only */\n' >> "$SRC/lua.h"
lb=$(links); run; e2=$(execs); la=$(links)
recompiled=$((e2 - e1))
if [ "$recompiled" -gt 20 ] && [ $((la - lb)) -eq 0 ]; then
  echo "ok   lua-header-edit: $recompiled TUs recompiled, link cut off"
else
  echo "FAIL lua-header-edit: $recompiled recompiles, $((la - lb)) links"; tail -3 "$TMP/out"; fail=1
fi
if cmp -s "$BUILD/lua" "$TMP/lua.saved"; then echo "ok   lua-binary-unchanged"
else echo "FAIL lua-binary-unchanged"; fail=1; fi

echo "-- rm -rf build: restore from store"
rm -rf "$BUILD"
run; e3=$(execs)
if [ "$e3" -eq "$e2" ] && cmp -s "$BUILD/lua" "$TMP/lua.saved" \
   && [ "$("$BUILD/lua" -e 'print(2^10)')" = "1024.0" ]; then
  echo "ok   lua-restored: zero re-runs, byte-identical, still computes"
else
  echo "FAIL lua-restored: $((e3 - e2)) execs"; fail=1
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== LUA BUILD (real-world Phase-1 proof) PASSED ==="; fi
exit $fail
