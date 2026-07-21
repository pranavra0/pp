#!/usr/bin/env bash
# Snapshot-as-CAS-ingest — torn reads are dead.
#
#   The first NODE-context observation of a file cell ingests its bytes into
#   the CAS (~/.pp/store/blobs/<sha256>) and pins (cell → hash) for the rest
#   of the run; every later node read of that cell is served from the pinned
#   CAS copy. Two nodes (or two reads) in one run can therefore never observe
#   two different versions of the same cell, even if an external writer
#   mutates the file mid-run. The run sees ONE world snapshot, taken lazily.
#
#   Scripting-tier reads bypass the pin (fresh read — the scripting tier is
#   openly impure), and a scripting-tier `write-file` INVALIDATES the pin so
#   pp's own writes stay coherent with later node reads.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
F="$TMP/cell.txt"

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# --- (a) torn read: an external writer mutates the file between two nodes;
#         both nodes observe the SAME (pinned) snapshot ---
cat > "$TMP/torn.pp" <<EOF
perform log(force(node { perform log("N1"); slurp("$F") }))
perform run("sh", "-c", "printf CHANGED > $F")
perform log(force(node {
  perform log("N2")
  slurp("$F")
}))
EOF
rm -rf "$TMP/.pp"
printf 'ORIG' > "$F"
run --grant "fs:$TMP:ro" --grant process "$TMP/torn.pp"
assert "torn-n1-ran"        "N1"      present
assert "torn-n2-ran"        "N2"      present
orig_count=$(grep -c "ORIG" "$TMP/out" || true)
if [ "$orig_count" -ge 2 ]; then echo "ok   torn-both-see-snapshot"
else echo "FAIL torn-both-see-snapshot: expected ORIG twice, got $orig_count"
     echo "--- output ---"; cat "$TMP/out"; fail=1; fi
assert "torn-no-mixed-view"  "\[info\] CHANGED" absent
if [ "$(cat "$F")" = "CHANGED" ]; then echo "ok   torn-disk-really-changed"
else echo "FAIL torn-disk-really-changed"; fail=1; fi

# --- (b) the observed bytes were ingested into the CAS ---
ORIG_HASH=$(printf 'ORIG' | shasum -a 256 | cut -d' ' -f1)
if [ -f "$TMP/.pp/store/blobs/$ORIG_HASH" ] \
   && [ "$(cat "$TMP/.pp/store/blobs/$ORIG_HASH")" = "ORIG" ]; then
  echo "ok   blob-ingested"
else
  echo "FAIL blob-ingested: blobs/$ORIG_HASH missing or wrong"; fail=1
fi

# --- (c) one run, one snapshot — at EVERY tier: a scripting read after an
#         external mid-run write also serves the pinned snapshot (the
#         in-memory CA dedup already memoizes identical read exprs, so
#         tier-split freshness was never coherent) ---
cat > "$TMP/tiers.pp" <<EOF
force(node { slurp("$F") })
perform run("sh", "-c", "printf CHANGED2 > $F")
perform log(slurp("$F"))
perform log(force(node {
  perform log("N3")
  slurp("$F")
}))
EOF
rm -rf "$TMP/.pp"
printf 'ORIG2' > "$F"
run --grant "fs:$TMP:ro" --grant process "$TMP/tiers.pp"
assert "scripting-sees-snapshot" "\[info\] CHANGED2" absent
assert "node-sees-snapshot"      "ORIG2"    present

# --- (d) pp's own scripting write-file invalidates the pin: later node
#         reads see the new content ---
cat > "$TMP/coherent.pp" <<EOF
force(node { slurp("$F") })
perform write-file("$F", "WRITTEN")
perform log(force(node {
  perform log("N4")
  slurp("$F")
}))
EOF
rm -rf "$TMP/.pp"
printf 'ORIG3' > "$F"
run --grant "fs:$TMP:rw" "$TMP/coherent.pp"
assert "own-write-coherent"   "WRITTEN" present
assert "own-write-not-stale"  "ORIG3"   absent

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CAS INGEST (Q11) TEST PASSED ==="; fi
exit $fail
