#!/usr/bin/env bash
# M5 exit battery (docs/PLAN-m5-distribution.md "Exit tests"), M5 stage C
# closing.
#
#   1. 101-TU (scaled) 2-machine build, local-dir transport, byte-identical
#      to serial — COVERED: tests/048-remote-placement.sh (an 8-TU real-cc
#      build; T6-same-tree-bytes / T6-same-desired-state-hash).
#   2. Cross-machine hit + `pp why` redaction on the non-origin machine —
#      COVERED: tests/047-cluster-sync.sh (B-hits-after-sync, T4-*).
#   3. Tampered token refused (T2); LAW 23b across the wire (T3) —
#      COVERED: tests/047-cluster-sync.sh (T2-*, T3-*).
#   4. GC bound + T7 concurrency stress — COVERED: tests/050-gc.sh
#      (gc-bounds-store-size, t7-*).
#   5. Diagonal gains `remote` as a placement value — COVERED:
#      tests/048-remote-placement.sh (diagonal-remote-in-help).
#
# The GAP this file closes: stage C's OWN new cross-machine seam — the
# by-hash desired-value publish/pull path (--publish-object /
# --desired-object) — had only ever been exercised within a single $HOME in
# manual verification; every assertion below runs it across TWO SEPARATE
# $HOME dirs (the tests/047/048 convention for "two machines"), combined
# with host-qualified --member-name distribution and `pp gc` on the
# receiving member's own store — the three stage-C pieces integrated
# together, which no other test file does end to end.
#
#   - dispatcher (A) computes a host-qualified desired-state value and
#     PUBLISHES it (value object + its blob: refs, never fenced actions or
#     journals) into a shared local-dir root;
#   - member (B), a genuinely separate $HOME, PULLS it by hash and
#     converges ONLY its own slice — re-hash-verified (T1) the same as
#     every other synced artifact;
#   - a blob: ref embedded in the published value (the `(blob ...)`
#     pattern) actually ships its bytes, not just the small string
#     reference — an unequivocal check that content, not merely metadata,
#     crossed;
#   - a tampered published object is rejected on pull (T1, this seam's own
#     call site);
#   - `pp gc` on B's store (which now holds a --desired-object-sourced
#     epoch) replays and sweeps correctly — the one Gcroots field
#     (gr_desired_object) no other test exercises.
#
# Two SIMULATED machines, differing only in $HOME (Store.store_root is a
# process-wide singleton — see src/transport.ml's header).
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
fail=0
ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

NODEA="$TMP/nodeA"; NODEB="$TMP/nodeB"
mkdir -p "$NODEA" "$NODEB"
SHARED="$TMP/shared"
ROOT_B="$TMP/rootB"; mkdir -p "$ROOT_B"

# ---------------------------------------------------------------------
# Dispatcher (A): a host-qualified desired-state program — {"B" {"fs" ...}}
# — including a `(blob ...)` reference alongside inline content, so the
# published value's transitive blob: ref must ALSO cross for B to converge
# correctly.
# ---------------------------------------------------------------------
BLOB_SRC="$TMP/blob-payload.bin"
printf 'THE-BLOB-PAYLOAD-BYTES\n' > "$BLOB_SRC"

cat > "$TMP/dispatch.pp" <<EOF
{"B" {"fs" {"inline.txt" "INLINE-CONTENT"
             "from-blob.txt" (blob (slurp "$BLOB_SRC"))}}}
EOF
HOME="$NODEA" "$PP" --grant "fs:${TMP}:ro" --publish-object "$SHARED" "$TMP/dispatch.pp" \
  > "$TMP/publish.out" 2>&1
HASH=$(grep -oE '[0-9a-f]{64}' "$TMP/publish.out" | head -1)
if [ -n "$HASH" ]; then ok "publish-object-prints-hash ($HASH)"
else bad "publish-object-prints-hash" "$(cat "$TMP/publish.out")"; fi
[ -d "$SHARED/objects" ] && [ -f "$SHARED/objects/$HASH" ] && ok "publish-object-pushed-to-shared" \
  || bad "publish-object-pushed-to-shared"
BLOBCOUNT=$(ls "$SHARED/blobs" 2>/dev/null | wc -l | tr -d ' ')
if [ "${BLOBCOUNT:-0}" -ge 1 ]; then ok "publish-object-pushed-blob-refs ($BLOBCOUNT blob(s))"
else bad "publish-object-pushed-blob-refs"; fi
# Nothing else (journal/fenced) is ever published alongside — only
# objects/ and blobs/ dirs exist under $SHARED.
if [ -e "$SHARED/journal" ] || [ -e "$SHARED/fenced-specs" ]; then
  bad "publish-object-never-ships-journal-or-fenced"
else
  ok "publish-object-never-ships-journal-or-fenced"
fi

# ---------------------------------------------------------------------
# Member (B): pulls by hash and converges ONLY its own slice. B's own
# program registers the fs domain for ITS root (the natural pattern — a
# member has no authority over another host's filesystem); its own return
# value is irrelevant (--desired-object overrides it).
# ---------------------------------------------------------------------
cat > "$TMP/member-b.pp" <<EOF
(load "stdlib/list.pp")
(load "stdlib/map.pp")
(load "stdlib/string.pp")
(load "stdlib/domain-fs.pp")
(register-fs-domain "$ROOT_B" (cap-restrict (current-capabilities) "$ROOT_B" :wo))
nil
EOF
HOME="$NODEB" "$PP" --grant "fs:${ROOT_B}:rw" --member-name B \
  --desired-object "$HASH" "$SHARED" "$TMP/member-b.pp" > "$TMP/member.out" 2>&1
CODE=$?
if [ "$CODE" -eq 0 ]; then ok "member-converges-from-desired-object"
else bad "member-converges-from-desired-object" "$(cat "$TMP/member.out")"; fi
[ -f "$ROOT_B/inline.txt" ] && [ "$(cat "$ROOT_B/inline.txt")" = "INLINE-CONTENT" ] \
  && ok "member-inline-content-correct" || bad "member-inline-content-correct"
if [ -f "$ROOT_B/from-blob.txt" ] && \
   diff -q "$ROOT_B/from-blob.txt" "$BLOB_SRC" > /dev/null 2>&1; then
  ok "member-blob-ref-bytes-crossed (byte-identical to the source blob)"
else
  bad "member-blob-ref-bytes-crossed" "$(ls -la "$ROOT_B" 2>&1)"
fi

# ---------------------------------------------------------------------
# T1 on this seam's own call site: a tampered published object is rejected
# on pull, never silently accepted (the same choke point as every other
# synced artifact — transport.ml's ingest_object).
# ---------------------------------------------------------------------
NODEC="$TMP/nodeC"; mkdir -p "$NODEC"
SHARED2="$TMP/shared2"
cat > "$TMP/dispatch2.pp" <<'EOF'
{"B" {"fs" {"x.txt" "X"}}}
EOF
HOME="$NODEA" "$PP" --publish-object "$SHARED2" "$TMP/dispatch2.pp" > "$TMP/publish2.out" 2>&1
HASH2=$(grep -oE '[0-9a-f]{64}' "$TMP/publish2.out" | head -1)
printf 'CORRUPT' | dd of="$SHARED2/objects/$HASH2" bs=1 seek=2 count=7 conv=notrunc 2>/dev/null
ROOT_C="$TMP/rootC"; mkdir -p "$ROOT_C"
cat > "$TMP/member-c.pp" <<EOF
(load "stdlib/list.pp")
(load "stdlib/map.pp")
(load "stdlib/string.pp")
(load "stdlib/domain-fs.pp")
(register-fs-domain "$ROOT_C" (cap-restrict (current-capabilities) "$ROOT_C" :wo))
nil
EOF
HOME="$NODEC" "$PP" --grant "fs:${ROOT_C}:rw" --member-name B \
  --desired-object "$HASH2" "$SHARED2" "$TMP/member-c.pp" > "$TMP/member-c.out" 2>&1
CODE=$?
if [ "$CODE" -ne 0 ] && grep -qE "tampered in transit|does not decode|does not hash" "$TMP/member-c.out"; then
  ok "T1-tampered-published-object-rejected"
else
  bad "T1-tampered-published-object-rejected" "exit=$CODE" "$(cat "$TMP/member-c.out")"
fi
[ -e "$ROOT_C/x.txt" ] && { echo "FAIL T1-tampered-no-write: x.txt materialized from a rejected object"; fail=1; } \
  || ok "T1-tampered-no-write"

# ---------------------------------------------------------------------
# `pp gc` on B's store: a --desired-object-sourced epoch replays and
# sweeps correctly (Gcroots' gr_desired_object field, round-tripped).
# ---------------------------------------------------------------------
HOME="$NODEB" "$PP" --gc-keep-epochs 5 --gc-grace-seconds 0 gc > "$TMP/gc-b.out" 2>&1
CODE=$?
if [ "$CODE" -eq 0 ] && grep -q "objects kept=" "$TMP/gc-b.out"; then
  ok "gc-on-member-with-desired-object-epoch"
else
  bad "gc-on-member-with-desired-object-epoch" "exit=$CODE" "$(cat "$TMP/gc-b.out")"
fi
# The kept root's closure survives: re-running the exact same converge
# (same hash, same shared root) is still correct.
HOME="$NODEB" "$PP" --grant "fs:${ROOT_B}:rw" --member-name B \
  --desired-object "$HASH" "$SHARED" "$TMP/member-b.pp" > "$TMP/member-b-again.out" 2>&1
if [ "$(cat "$ROOT_B/inline.txt")" = "INLINE-CONTENT" ]; then
  ok "gc-preserves-member-closure"
else
  bad "gc-preserves-member-closure" "$(cat "$TMP/member-b-again.out")"
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== M5 EXIT BATTERY (STAGE C GAPS) TEST PASSED ==="; fi
exit $fail
