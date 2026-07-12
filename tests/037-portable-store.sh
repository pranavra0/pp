#!/usr/bin/env bash
# M2.2: versioned portable store format (ROADMAP maturity §3).
#
#   ~/.pp/store serializes with a canonical, byte-stable TEXT codec
#   (src/codec.ml) instead of OCaml Marshal, stamped by store/VERSION
#   ("pp-store 1"). The bytes must be identical on any OS/arch/compiler.
#
#   Covers (task spec, five clauses; both backends where applicable):
#     (a) golden bytes — a fixed program's stored object file and trace file
#         are byte-identical (names AND content) to fixtures checked into
#         tests/fixtures/store-v1/, from both backends: the single-machine
#         cross-arch proof until Linux CI;
#     (b) codec round-trip battery — a node result exercising negative ints,
#         -0.0, 1e308, 0.1, nan, inf, -inf, strings with quotes/backslashes/
#         newlines/control bytes/UTF-8, keywords, symbols, nested vectors,
#         maps with map keys and mixed-type keys, sets, improper pairs:
#         stored in one process, HIT in a second process (pp why says so),
#         printed byte-identically — and the hit crosses backends;
#     (c) version bump — VERSION overwritten with "pp-store 0": next run
#         exits 0, recomputes cold, re-stamps VERSION, wipes objects/ but
#         preserves journal/ and blobs/;
#     (d) closure result — a closure-valued node stores NO object (the
#         non-data law: the store holds data, code is process-local), a
#         second process recomputes it without error, and a data-valued
#         node in the same program still hits cross-process;
#     (e) legacy store — garbage (Marshal-era) bytes in objects/ and
#         traces/ with no VERSION: next run wipes cleanly, rebuilds, exit 0.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
FIX="$PWD/tests/fixtures/store-v1"

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

STORE="$TMP/.pp/store"

# --- (a) golden bytes: object + trace files byte-identical to fixtures ---
# The program is run by its RELATIVE name from a scratch cwd so no
# machine-specific path enters the node key (ELocated hashes the file name
# as given). Fixture file NAMES pin the node key and result hash; fixture
# BYTES pin the codec output.
golden_run() {  # BACKEND-FLAGS...
  rm -rf "$TMP/.pp" "$TMP/golden"
  mkdir -p "$TMP/golden"
  cp "$FIX/golden.pp" "$TMP/golden/"
  (cd "$TMP/golden" && "$PP" "$@" golden.pp) > "$TMP/out" 2>&1
}
golden_check() {  # LABEL
  local label="$1" kind
  for kind in objects traces; do
    for f in "$FIX/$kind"/*; do
      local name got
      name=$(basename "$f")
      got="$STORE/$kind/$name"
      if [ ! -f "$got" ]; then
        echo "FAIL $label-$kind-name: $name not in store"; fail=1
      elif ! cmp -s "$f" "$got"; then
        echo "FAIL $label-$kind-bytes: $name differs from fixture"
        echo "--- fixture ---"; cat "$f"; echo "--- got ---"; cat "$got"; fail=1
      else
        echo "ok   $label-$kind"
      fi
    done
    local count
    count=$(ls "$STORE/$kind" | wc -l | tr -d ' ')
    if [ "$count" -eq 1 ]; then echo "ok   $label-$kind-count"
    else echo "FAIL $label-$kind-count: expected 1 file, got $count"; fail=1; fi
  done
}
golden_run
golden_check "tw-golden"
golden_run --bytecode
golden_check "bc-golden"

# --- (b) codec round-trip battery ---
# printf embeds REAL control bytes (\x01, \x7f) and raw UTF-8 in the source
# string. The map literal is written in the codec's canonical key order so
# a decoded (hit) value prints byte-identically to the freshly computed one.
printf '(let [inf (* 1.0e308 10.0)]\n  (print (force (node (do (perform log "COMPUTE") [(- 0 5) (* -1.0 0.0) 1.0e308 0.1 inf (- 0.0 inf) (- inf inf) "q\\"b\\\\s nl\\n tab\\t ctrl\x01\x7f uni\xc3\xa9" :akey (quote asym) [1 [2 [3]]] {1 "i" :k 2 {"m" 1} 3 "s" 4} #{1 2 3} (cons 1 2)])))))\n' \
  > "$TMP/battery.pp"

battery() {  # LABEL COLD-FLAGS... — cold store, then re-run cross-process/backend
  local label="$1"; shift
  rm -rf "$TMP/.pp"
  "$PP" "$@" "$TMP/battery.pp" > "$TMP/run1.out" 2>&1
  assert "$label-cold-computes" "COMPUTE" present "$TMP/run1.out"
}
check_hit() {  # LABEL RUN-FLAGS...
  local label="$1"; shift
  "$PP" "$@" "$TMP/battery.pp" > "$TMP/run2.out" 2>&1
  assert "$label-no-recompute" "COMPUTE" absent "$TMP/run2.out"
  if diff <(grep -v COMPUTE "$TMP/run1.out") "$TMP/run2.out" > /dev/null; then
    echo "ok   $label-print-identical"
  else
    echo "FAIL $label-print-identical:"
    diff <(grep -v COMPUTE "$TMP/run1.out") "$TMP/run2.out"; fail=1
  fi
  "$PP" why "$@" "$TMP/battery.pp" > /dev/null 2> "$TMP/why.out"
  assert "$label-why-hit" "hit — ok trace verified" present "$TMP/why.out"
}
battery "tw-battery"
check_hit "tw-battery-hit"                       # tree-walker → tree-walker
check_hit "tw-to-bc-battery-hit" --bytecode      # tree-walker → bytecode
battery "bc-battery" --bytecode
check_hit "bc-battery-hit" --bytecode            # bytecode → bytecode
check_hit "bc-to-tw-battery-hit"                 # bytecode → tree-walker

# --- (c) version bump: wipe + re-stamp, never crash; journal/blobs kept ---
rm -rf "$TMP/.pp"
"$PP" "$TMP/battery.pp" > "$TMP/run1.out" 2>&1
mkdir -p "$STORE/journal" "$STORE/blobs"
echo "audit-sentinel-line" >> "$STORE/journal/log"
echo "blob-sentinel-bytes" > "$STORE/blobs/sentinel"
touch "$STORE/objects/stale-format-leftover"
printf 'pp-store 0\n' > "$STORE/VERSION"
"$PP" "$TMP/battery.pp" > "$TMP/out" 2>&1
if [ $? -eq 0 ]; then echo "ok   bump-exit-0"
else echo "FAIL bump-exit-0"; cat "$TMP/out"; fail=1; fi
assert "bump-recomputes-cold" "COMPUTE" present
if [ "$(cat "$STORE/VERSION")" = "pp-store 1" ]; then echo "ok   bump-restamped"
else echo "FAIL bump-restamped: $(cat "$STORE/VERSION" 2>/dev/null)"; fail=1; fi
[ -f "$STORE/objects/stale-format-leftover" ] \
  && { echo "FAIL bump-wipes-objects: stale file survived"; fail=1; } \
  || echo "ok   bump-wipes-objects"
grep -q "audit-sentinel-line" "$STORE/journal/log" \
  && echo "ok   bump-keeps-journal" \
  || { echo "FAIL bump-keeps-journal"; fail=1; }
[ -f "$STORE/blobs/sentinel" ] && echo "ok   bump-keeps-blobs" \
  || { echo "FAIL bump-keeps-blobs"; fail=1; }

# --- (d) closure-valued node: no object stored, recompute is clean, and a
#         data node in the same program still hits cross-process ---
cat > "$TMP/closure.pp" <<'EOF'
(def datan (node (do (perform log "COMPUTE-DATA") "data-42")))
(def fnnode (node (do (perform log "COMPUTE-FN") (fn [x] x))))
(print (force datan))
(print ((force fnnode) "applied"))
EOF
closure_case() {  # LABEL FLAGS...
  local label="$1"; shift
  rm -rf "$TMP/.pp"
  "$PP" "$@" "$TMP/closure.pp" > "$TMP/out" 2>&1
  assert "$label-run1-data-computes" "COMPUTE-DATA" present
  assert "$label-run1-fn-computes" "COMPUTE-FN" present
  assert "$label-run1-value" "data-42" present
  assert "$label-run1-applied" "applied" present
  # The non-data law: exactly one object (the string), none for the closure.
  local count
  count=$(ls "$STORE/objects" | wc -l | tr -d ' ')
  if [ "$count" -eq 1 ] && grep -q '(s "data-42")' "$STORE/objects"/*; then
    echo "ok   $label-no-closure-object"
  else
    echo "FAIL $label-no-closure-object: $count object(s):"
    for f in "$STORE/objects"/*; do cat "$f"; echo; done; fail=1
  fi
  "$PP" "$@" "$TMP/closure.pp" > "$TMP/out" 2>&1
  if [ $? -eq 0 ]; then echo "ok   $label-run2-exit-0"
  else echo "FAIL $label-run2-exit-0"; cat "$TMP/out"; fail=1; fi
  assert "$label-run2-data-hits" "COMPUTE-DATA" absent
  assert "$label-run2-fn-recomputes" "COMPUTE-FN" present
  assert "$label-run2-applied" "applied" present
}
closure_case "tw-closure"
closure_case "bc-closure" --bytecode

# --- (e) legacy (Marshal-era) store: garbage bytes, no VERSION → clean wipe ---
rm -rf "$TMP/.pp"
mkdir -p "$STORE/objects" "$STORE/traces" "$STORE/journal"
printf '\x84\x95\xa6\xbe\x00\x00\x00\x1cMarshal-era garbage\x01\x02' \
  > "$STORE/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
printf '\x84\x95\xa6\xbe binary trace junk \xff\xfe' \
  > "$STORE/traces/fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
echo "pre-migration-audit-line" >> "$STORE/journal/log"
"$PP" "$TMP/battery.pp" > "$TMP/out" 2>&1
if [ $? -eq 0 ]; then echo "ok   legacy-exit-0"
else echo "FAIL legacy-exit-0"; cat "$TMP/out"; fail=1; fi
assert "legacy-recomputes" "COMPUTE" present
[ -f "$STORE/objects/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef" ] \
  && { echo "FAIL legacy-wipes-garbage-object"; fail=1; } \
  || echo "ok   legacy-wipes-garbage-object"
[ -f "$STORE/traces/fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210" ] \
  && { echo "FAIL legacy-wipes-garbage-trace"; fail=1; } \
  || echo "ok   legacy-wipes-garbage-trace"
if [ "$(cat "$STORE/VERSION" 2>/dev/null)" = "pp-store 1" ]; then echo "ok   legacy-stamped"
else echo "FAIL legacy-stamped"; fail=1; fi
grep -q "pre-migration-audit-line" "$STORE/journal/log" \
  && echo "ok   legacy-keeps-journal" \
  || { echo "FAIL legacy-keeps-journal"; fail=1; }

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PORTABLE STORE (M2.2) TEST PASSED ==="; fi
exit $fail
