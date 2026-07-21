#!/usr/bin/env bash
# Islands: content-addressed modules with INLINE pins.
#
#   (island file:./lib "64-hex-pin") resolves to an immutable cached tree
#   under ~/.pp/islands/src/<pin>/, verified against the pin on every
#   resolve. The pin is part of the code hash (SPEC law 20), so island identity
#   is structural: no lockfile, no synthetic cell. An unpinned form is a
#   hard error; `pp --update` re-resolves and rewrites pins in the source.
#
#   The network half (git:/github: fetch) is exercised only under
#   PP_ISLAND_NET_TEST=1, against a LOCAL bare repo (no real network).
#
# Runs under an isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$TMP"

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

run_one() {  # ARGS... — run single engine, leave output in $TMP/out
  "$PP" "$@" > "$TMP/out" 2>&1
}

# --- fixture island ---
# `.pp` now dispatches to the brace reader, so every embedded program below
# is brace syntax (`island("URI"[, "PIN"])` — braces spell URIs as strings).
mkdir -p lib
cat > lib/entry.pp <<'EOF'
let isl-x = 42
def isl-double(n) { n * 2 }
EOF

# --- (1) parse & scheme dispatch ---
echo 'island("nope:foo", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")' > bad-scheme.pp
run_one bad-scheme.pp
assert "scheme-error" "island: unknown scheme in URI: nope:foo" present

echo 'island("file:./lib", "v1.0")' > bad-pin.pp
run_one bad-pin.pp
assert "bad-pin-error" "pin for file:./lib must be a 64-hex content hash" present

# --- (2) unpinned is a hard error naming the fix ---
cat > prog.pp <<'EOF'
import(island("file:./lib"))
print(isl-double(isl-x))
EOF
run_one prog.pp
assert "unpinned-error" "island: no pin for file:./lib; run pp --update" present

# --- (3) --update rewrites the inline pin; import binds exports ---
"$PP" --update prog.pp > "$TMP/out" 2>&1
assert "update-ran" "1 pin\(s\) updated" present
PIN=$(grep -oE '[0-9a-f]{64}' prog.pp | head -1)
[ -n "$PIN" ] && echo "ok   pin-inlined" || { echo "FAIL pin-inlined: no pin in prog.pp"; fail=1; }
run_one prog.pp
assert "pinned-value" "^84$" present

# --- (4) pin is content-addressed & stable ---
cp -R lib lib2
cat > prog2.pp <<'EOF'
import(island("file:./lib2"))
print(isl-x)
EOF
"$PP" --update prog2.pp > /dev/null 2>&1
PIN2=$(grep -oE '[0-9a-f]{64}' prog2.pp | head -1)
if [ "$PIN" = "$PIN2" ]; then echo "ok   pin-stable"
else echo "FAIL pin-stable: identical trees pinned differently ($PIN vs $PIN2)"; fail=1; fi

# --- (5) island import is a node boundary (cold run, hit, cache reuse) ---
cat > nprog.pp <<EOF
import(island("file:./lib", "$PIN"))
perform log(force(node { perform log("RUN"); number->string(isl-x * 2) }))
EOF
rm -rf "$TMP/.pp/store"
"$PP" nprog.pp > "$TMP/out" 2>&1
assert "node-cold" "RUN" present
"$PP" nprog.pp > "$TMP/out" 2>&1
assert "node-hit" "RUN" absent
assert "node-hit-value" "84" present
"$PP" nprog.pp > "$TMP/out" 2>&1
assert "node-shared-hit" "RUN" absent
assert "node-value" "84" present

# --- (6) editing the source dir does nothing (pinned); --update re-pins ---
printf 'let isl-x = 99\ndef isl-double(n) { n * 2 }\n' > lib/entry.pp
run_one prog.pp
assert "pinned-frozen-value" "^84$" present
"$PP" why prog.pp > "$TMP/out" 2>&1
assert "why-drift" "source dir now hashes .* run pp --update" present
"$PP" --update prog.pp > /dev/null 2>&1
NEWPIN=$(grep -oE '[0-9a-f]{64}' prog.pp | head -1)
if [ "$NEWPIN" != "$PIN" ]; then echo "ok   repin-changed"
else echo "FAIL repin-changed: pin did not move on content change"; fail=1; fi
run_one prog.pp
assert "repinned-value" "^198$" present

# --- (7) tamper check ---
printf 'x' >> "$TMP/.pp/islands/src/$NEWPIN/entry.pp"
run_one prog.pp
assert "tamper-error" "island: cache tamper detected" present
rm -rf "$TMP/.pp/islands/src/$NEWPIN"

# --- (8) offline reproducibility: source dir gone, cache + inline pin win ---
"$PP" prog.pp > /dev/null 2>&1   # re-fill cache from source (hash matches pin)
rm -rf lib
run_one prog.pp
assert "offline-value" "^198$" present

# --- (9) pinned-but-uncached git island errors cleanly with fetch off ---
echo 'island("github:foo/bar#main", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")' > g.pp
run_one g.pp
assert "git-uncached-error" "not in the cache; run pp --fetch-islands" present

# --- (10) island-pins introspection ---
"$PP" island-pins prog.pp > "$TMP/out" 2>&1
assert "island-pins" "file:./lib\s+$NEWPIN\s+cached" present

# --- (11) network half: LOCAL bare repo as the remote (opt-in) ---
if [ "${PP_ISLAND_NET_TEST:-0}" = "1" ]; then
  mkdir -p srcrepo && cd srcrepo
  git init -q 2>/dev/null && git config user.email t@t && git config user.name t
  echo 'let isl-net = 7' > entry.pp
  git add entry.pp && git commit -qm one
  cd "$TMP"
  git clone -q --bare srcrepo remote.git
  cat > netprog.pp <<EOF
import(island("git:$TMP/remote.git#master"))
print(isl-net)
EOF
  "$PP" netprog.pp > "$TMP/out" 2>&1
  assert "net-unpinned-error" "no pin for" present
  "$PP" --update netprog.pp > "$TMP/out" 2>&1
  both "net-pinned" netprog.pp
  assert "net-value" "^7$" present
  grep -q "island fetch" "$TMP/.pp/store/journal/log" \
    && echo "ok   net-journaled" || { echo "FAIL net-journaled"; fail=1; }
else
  echo "ok   net-subcase-skipped (set PP_ISLAND_NET_TEST=1 to run)"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== ISLANDS TEST PASSED ==="; fi
exit $fail
