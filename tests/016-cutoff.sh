#!/usr/bin/env bash
# pins: LAW-21
# Cutoff at node granularity.
#
#   Touching an input (mtime change, no content change) rebuilds NOTHING.
#   Trace validity is content-hash re-observation; mtime never enters
#   (SPEC law 21).
#
#   An edit that changes an input but NOT the derived value cuts off
#   downstream recompute. The mechanism is value-based keying, not a
#   dirty-propagation graph: a downstream node keyed on an upstream node's
#   *value* (free-var value hash) re-keys identically when a recompute
#   produces a byte-identical result, so the downstream is a hit while the
#   upstream re-ran (SPEC law 20).
#
# The model build: "compile" reads a header AND a source but its value depends
# only on the source (like a .o that is invariant under header comments);
# "link" is a node whose free variable is the compile result. Editing the
# header ⇒ COMPILE re-runs (its trace has the header's file cell), LINK hits
# (same object value ⇒ same key, and its own trace never read the header).
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

printf 'H1\n' > "$TMP/h.h"
printf 'BODY\n' > "$TMP/a.c"

cat > "$TMP/build.pp" <<EOF
let (obj = force(node {
  perform log("COMPILE")
  do {
    slurp("$TMP/h.h")
    slurp("$TMP/a.c")
  }
})) {
  perform log(force(node {
    perform log("LINK")
    string-append("linked:", obj)
  }))
}
EOF

run() { "$PP" "$@" --grant "fs:$TMP:ro" "$TMP/build.pp" > "$TMP/out" 2>&1; }

# --- run 1: cold build — everything computes ---
rm -rf "$TMP/.pp"
run
assert "cold-compile"        "COMPILE"      present
assert "cold-link"           "LINK"         present
assert "cold-value"          "linked:BODY"  present

# --- run 2: null build — zero recomputes ---
run
assert "null-no-compile"     "COMPILE"      absent
assert "null-no-link"        "LINK"         absent
assert "null-value-served"   "linked:BODY"  present

# --- run 3: touch both inputs (mtime only), contents unchanged ---
touch -t 202001010000 "$TMP/h.h" "$TMP/a.c"
run
assert "touch-no-compile"    "COMPILE"      absent
assert "touch-no-link"       "LINK"         absent
assert "touch-value-served"  "linked:BODY"  present

# --- run 4: header edit that leaves the compiled object identical ---
printf 'H2 comment-only\n' > "$TMP/h.h"
run
assert "hdr-edit-recompiles" "COMPILE"      present   # trace has h.h's cell
assert "hdr-edit-link-cutoff" "LINK"        absent    # same obj value ⇒ same key
assert "hdr-edit-value"      "linked:BODY"  present

# --- run 5: source edit — the whole chain re-runs with the new value ---
printf 'BODY2\n' > "$TMP/a.c"
run
assert "src-edit-recompiles" "COMPILE"      present
assert "src-edit-relinks"    "LINK"         present
assert "src-edit-value"      "linked:BODY2" present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CUTOFF (LAW 21) TEST PASSED ==="; fi
exit $fail
