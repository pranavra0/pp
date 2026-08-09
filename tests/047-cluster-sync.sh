#!/usr/bin/env bash
# Cluster transport: signed access tokens gate synced builds, and content
# is synced by hash rather than trusted paths. See
# docs/THREAT-MODEL-cluster.md for the threat model this guards against.
#
# Two SIMULATED cluster members are two `pp` process invocations differing
# only in $HOME (the default repository layout is fixed at startup, so
# "two stores" means "two processes" — see transport.ml's
# module header); they share a WORK dir (the underlying "world" both
# members can observe identically, like tests/019) and a cluster
# secret/id distributed out of band via a plain file copy (simulating
# `pp cluster-init` + scp).
#
#   Corrupting a byte in a copied artifact (object, blob, trace) makes the
#     receiving --transport-pull reject it via re-hash-on-receive (case T1
#     below).
#   A tampered-MAC token, and an expired token, are both denied by
#     --serve-hit before cache lookup (case T2 below).
#   A token whose capabilities don't cover the trace's read closure gets a
#     MISS from --serve-hit, even though the bytes are on local disk — a
#     broader token gets a hit for the SAME key (authority is re-checked
#     against the trace's read closure even across the wire, per SPEC law
#     23b; case T3 below).
#   `pp why` over the SYNCED trace, on the receiving node, redacts exactly
#     like a local run under the same narrow grant (case T4 below).
#   A node touching a sealed value is never stored at all (the existing
#     node-boundary ban on sealed values), so there is nothing for
#     serve-hit to ship; a whole-tree grep for the secret's content,
#     across every directory anything crossed through, finds nothing
#     (case T5 below).
#   The result hash served via serve-hit/recv-hit is byte-identical to
#     (a) what a fresh independent build of the same program computes,
#     and (b) the node key is the same filename in both members' traces/
#     directories (case T6 below, partial).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  local got
  if grep -qE "$pat" "$file" 2>/dev/null; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode in $file, got $got"
    echo "--- $file ---"; cat "$file" 2>/dev/null; fail=1
  fi
}

assert_exit() {  # NAME EXPECTED_CODE ACTUAL_CODE
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then echo "ok   $name"
  else echo "FAIL $name: expected exit $expected, got $actual"; fail=1; fi
}

# Flips one byte at OFFSET in FILE to a different value — dd/od only, no
# python dependency (unlike tests/045, which legitimately needs an HTTP
# server). Avoids producing a newline byte, which would inject a spurious
# line break into a single-line canonical-text artifact.
flip_byte() {  # FILE OFFSET
  local f="$1" off="$2" cur newval
  cur=$(dd if="$f" bs=1 skip="$off" count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
  newval=$(( (cur + 1) % 256 ))
  if [ "$newval" -eq 10 ]; then newval=11; fi
  printf "$(printf '\\%03o' "$newval")" | dd of="$f" bs=1 seek="$off" count=1 conv=notrunc 2>/dev/null
}

WORK="$TMP/work"; OTHER="$TMP/other"
mkdir -p "$WORK" "$OTHER"
printf 'V1\n' > "${WORK}/data.txt"

NODEA="$TMP/nodeA"; NODEB="$TMP/nodeB"; NODEC="$TMP/nodeC"
mkdir -p "$NODEA" "$NODEB" "$NODEC"

cat > "$TMP/prog.pp" <<EOF
perform log(force(node {
  perform log("COMPUTE")
  slurp("${WORK}/data.txt")
}))
EOF

# ---------------------------------------------------------------------
# Setup: cluster-init on the root (A), distribute secret+id out of band
# (a plain file copy — the operator's job per docs/THREAT-MODEL-cluster.md).
# ---------------------------------------------------------------------
HOME="$NODEA" "$PP" cluster-init > "$TMP/out" 2>&1
assert "cluster-init-mints-secret" "minted" present
[ -f "$NODEA/.pp/cluster/secret" ] && [ -f "$NODEA/.pp/cluster/id" ] \
  && echo "ok   cluster-init-files-exist" || { echo "FAIL cluster-init-files-exist"; fail=1; }
PERMS=$(ls -l "$NODEA/.pp/cluster/secret" | cut -c1-10)
case "$PERMS" in
  -rw-------) echo "ok   cluster-secret-mode-0600" ;;
  *) echo "FAIL cluster-secret-mode-0600: got $PERMS"; fail=1 ;;
esac

mkdir -p "$NODEB/.pp/cluster" "$NODEC/.pp/cluster"
cp "$NODEA/.pp/cluster/secret" "$NODEA/.pp/cluster/id" "$NODEB/.pp/cluster/"
cp "$NODEA/.pp/cluster/secret" "$NODEA/.pp/cluster/id" "$NODEC/.pp/cluster/"

# A second cluster-init must refuse rather than silently rotate.
HOME="$NODEA" "$PP" cluster-init > "$TMP/out" 2>&1
assert "cluster-init-refuses-overwrite" "already exists" present

# ---------------------------------------------------------------------
# Build the node on A.
# ---------------------------------------------------------------------
HOME="$NODEA" "$PP" --grant "fs:${WORK}:ro" "$TMP/prog.pp" > "$TMP/out" 2>&1
assert "buildA-computes" "COMPUTE" present
assert "buildA-result" "\[info\] V1" present
KEY=$(ls "$NODEA/.pp/store/traces")
RESULT_HASH=$(grep -oE '"[0-9a-f]{64,}"' "$NODEA/.pp/store/traces/$KEY" | head -1 | tr -d '"')
[ -n "$KEY" ] && [ -n "$RESULT_HASH" ] || { echo "FAIL setup: could not read key/result-hash"; exit 1; }
# Source-free desired-object convergence: publish a canonical tree object,
# then materialize it on a fresh root without a program or REPL input.
DESIRED_OUT="$TMP/desired-out"; DESIRED_SHARED="$TMP/desired-shared"
cat > "$TMP/desired-tree.pp" <<EOF
{:fs -> {:tree -> {
  "a.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("DESIRED-A")},
  "sub" -> {:kind -> :directory, :mode -> 493},
  "sub/b.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("DESIRED-B")}
}}}
EOF
PUBLISH_OUT=$(HOME="$NODEA" "$PP" --publish-object "$DESIRED_SHARED" \
  "$TMP/desired-tree.pp" 2>&1)
DESIRED_HASH=$(printf '%s\n' "$PUBLISH_OUT" | grep -oE '[0-9a-f]{64}' | head -1)
[ -n "$DESIRED_HASH" ] || { echo "FAIL desired-object-publish-hash"; fail=1; }
rm -rf "$DESIRED_OUT"
HOME="$NODEC" "$PP" --desired-object "$DESIRED_HASH" "$DESIRED_SHARED" \
  --reconcile "$DESIRED_OUT" --grant "fs:${DESIRED_OUT}:rw" \
  </dev/null > "$TMP/desired-object.out" 2>&1
CODE=$?
assert_exit "desired-object-converges-exit" 0 "$CODE"
assert "desired-object-no-repl" "REPL|pp>" absent "$TMP/desired-object.out"
if [ -f "$DESIRED_OUT/a.txt" ] && [ "$(cat "$DESIRED_OUT/a.txt")" = "DESIRED-A" ] \
  && [ -f "$DESIRED_OUT/sub/b.txt" ] && [ "$(cat "$DESIRED_OUT/sub/b.txt")" = "DESIRED-B" ]; then
  echo "ok   desired-object-materializes-tree"
else
  echo "FAIL desired-object-materializes-tree: expected files/content"; fail=1
fi
if [ "$(stat -c '%a' "$DESIRED_OUT/a.txt" 2>/dev/null)" = "644" ] \
  && [ "$(stat -c '%a' "$DESIRED_OUT/sub" 2>/dev/null)" = "755" ]; then
  echo "ok   desired-object-materializes-modes"
else
  echo "FAIL desired-object-materializes-modes: expected 644/755"; fail=1
fi


# ---------------------------------------------------------------------
# Tokens: a broad grant covering WORK, a narrow grant that doesn't, a
# tampered token, and an expired token (case T2 below).
# ---------------------------------------------------------------------
HOME="$NODEA" "$PP" --grant "fs:${WORK}:ro" --mint-token "$TMP/token-broad.txt" 3600
HOME="$NODEA" "$PP" --grant "fs:${OTHER}:ro" --mint-token "$TMP/token-narrow.txt" 3600
HOME="$NODEA" "$PP" --grant "fs:${WORK}:ro" --mint-token "$TMP/token-expired.txt" -100
cp "$TMP/token-broad.txt" "$TMP/token-tampered.txt"
# Flip a byte inside the quoted MAC (well after the header — safe to target
# a fixed late offset since the MAC is the LAST field before the closing paren).
MACLEN=$(wc -c < "$TMP/token-tampered.txt")
flip_byte "$TMP/token-tampered.txt" $(( MACLEN - 6 ))

SHARED="$TMP/shared"

HOME="$NODEA" "$PP" --serve-hit "$KEY" "$TMP/token-tampered.txt" "$SHARED" "$TMP/reply-tampered.txt" > "$TMP/out" 2>&1
assert "T2-tampered-mac-denied" "deny" present "$TMP/reply-tampered.txt"
assert "T2-tampered-mac-reason" "MAC mismatch" present "$TMP/reply-tampered.txt"
[ -d "$SHARED" ] && { echo "FAIL T2-tampered-no-push: shared root exists after a denied token"; fail=1; } \
  || echo "ok   T2-tampered-no-push"

HOME="$NODEA" "$PP" --serve-hit "$KEY" "$TMP/token-expired.txt" "$SHARED" "$TMP/reply-expired.txt" > "$TMP/out" 2>&1
assert "T2-expired-denied" "deny" present "$TMP/reply-expired.txt"
assert "T2-expired-reason" "expired" present "$TMP/reply-expired.txt"

# ---------------------------------------------------------------------
# A token whose capabilities don't cover the node's read closure gets a
# MISS, even though the bytes are on A's local disk; the SAME key with a
# covering token gets a hit — proving it's the token, not the key, that's
# the variable (SPEC law 23b enforced across the wire; case T3 below).
# ---------------------------------------------------------------------
HOME="$NODEA" "$PP" --serve-hit "$KEY" "$TMP/token-narrow.txt" "$SHARED" "$TMP/reply-narrow.txt" > "$TMP/out" 2>&1
assert "T3-unauthorized-closure-miss" "serve-hit-reply miss" present "$TMP/reply-narrow.txt"
[ -d "$SHARED" ] && { echo "FAIL T3-no-push-on-miss: shared root exists after an unauthorized miss"; fail=1; } \
  || echo "ok   T3-no-push-on-miss"

HOME="$NODEA" "$PP" --serve-hit "$KEY" "$TMP/token-broad.txt" "$SHARED" "$TMP/reply-broad.txt" > "$TMP/out" 2>&1
# Match the verdict token, not a bare "hit": "serve-hit-reply" itself
# contains the substring "hit", so `grep hit` passes even on a miss reply.
assert "T3-authorized-closure-hit" "serve-hit-reply hit" present "$TMP/reply-broad.txt"
assert "reply-names-result-hash" "$RESULT_HASH" present "$TMP/reply-broad.txt"

# ---------------------------------------------------------------------
# recv-hit on B: pulls the pushed object+trace, re-hash-verifying, into
# B's OWN store.
# ---------------------------------------------------------------------
HOME="$NODEB" "$PP" --recv-hit "$TMP/reply-broad.txt" "$SHARED" > "$TMP/out" 2>&1
assert "recv-hit-reports-hit" "recv-hit: hit" present
assert "recv-hit-result-hash" "$RESULT_HASH" present

# B now hits LOCALLY, with no recompute (proves the synced trace verifies
# against the shared WORK dir exactly like a locally-built one).
HOME="$NODEB" "$PP" why --grant "fs:${WORK}:ro" "$TMP/prog.pp" > "$TMP/out" 2>&1
assert "B-hits-after-sync" "\[why\].*hit" present
assert "B-no-recompute" "COMPUTE" absent
assert "B-correct-result" "\[info\] V1" present

# ---------------------------------------------------------------------
# Why-redaction survives sync: B, under a narrow grant that does NOT
# cover WORK, redacts the synced trace's cell exactly like A does locally
# under the same narrow grant — same markers, same absence of the real
# path (case T4 below).
# ---------------------------------------------------------------------
HOME="$NODEA" "$PP" why --grant "fs:${OTHER}:ro" "$TMP/prog.pp" > "$TMP/local-why.out" 2>&1
HOME="$NODEB" "$PP" why --grant "fs:${OTHER}:ro" "$TMP/prog.pp" > "$TMP/synced-why.out" 2>&1
for f in "$TMP/local-why.out" "$TMP/synced-why.out"; do
  assert "T4-redacted-marker" "<redacted unauthorized cell>" present "$f"
  assert "T4-unauthorized-reported" "unauthorized" present "$f"
  # Scoped to `[why]` lines only (like tests/019's why-no-secret-leak): the
  # program's OWN subsequent recompute attempt legitimately fails and names
  # the path in its ordinary capability-error line — that's the caller's own
  # denied read, not a `why`/trace redaction leak, so it must not fail this
  # check the way a bare (unscoped) path match would.
  assert "T4-path-not-leaked" "\[why\].*data\.txt" absent "$f"
done

# ---------------------------------------------------------------------
# Re-hash-on-receive: corrupt a byte in a copied object, blob, and trace;
# --transport-pull must reject every one of them, never silently accept
# (case T1 below).
# ---------------------------------------------------------------------
SHARED2="$TMP/shared2"
HOME="$NODEA" "$PP" --transport-push object "$RESULT_HASH" "$SHARED2"
flip_byte "$SHARED2/objects/$RESULT_HASH" 5
HOME="$NODEC" "$PP" --transport-pull object "$RESULT_HASH" "$SHARED2" > "$TMP/out" 2>&1
CODE=$?
assert_exit "T1-object-corruption-rejected-exit" 1 "$CODE"
assert "T1-object-corruption-message" "tampered in transit" present

BLOB_HASH=$(grep -oE '"file:[^"]*" \. "[0-9a-f]{64,}"' "$NODEA/.pp/store/traces/$KEY" \
  | grep -oE '"[0-9a-f]{64,}"' | tr -d '"')
if [ -n "$BLOB_HASH" ] && [ -f "$NODEA/.pp/store/blobs/$BLOB_HASH" ]; then
  HOME="$NODEA" "$PP" --transport-push blob "$BLOB_HASH" "$SHARED2"
  flip_byte "$SHARED2/blobs/$BLOB_HASH" 0
  HOME="$NODEC" "$PP" --transport-pull blob "$BLOB_HASH" "$SHARED2" > "$TMP/out" 2>&1
  CODE=$?
  assert_exit "T1-blob-corruption-rejected-exit" 1 "$CODE"
  assert "T1-blob-corruption-message" "tampered in transit" present
else
  echo "skip T1-blob-corruption: no blob-backed file cell recorded"
fi

HOME="$NODEA" "$PP" --transport-push trace "$KEY" "$SHARED2"
# Truncate rather than flip-in-place: a single flipped byte inside an
# escaped hex sequence can still parse as a (different, wrong) trace since
# traces have no self-hash to check against — truncation reliably breaks
# the grammar, which is exactly what a torn/corrupted transfer looks like.
TRACE_LEN=$(wc -c < "$SHARED2/traces/$KEY")
dd if="$SHARED2/traces/$KEY" of="$TMP/trace-trunc" bs=1 count=$(( TRACE_LEN - 5 )) 2>/dev/null
mv "$TMP/trace-trunc" "$SHARED2/traces/$KEY"
HOME="$NODEC" "$PP" --transport-pull trace "$KEY" "$SHARED2" > "$TMP/out" 2>&1
CODE=$?
assert_exit "T1-trace-corruption-rejected-exit" 1 "$CODE"
assert "T1-trace-corruption-message" "tampered in transit" present

# ---------------------------------------------------------------------
# Sealed non-regression: a node touching a secret is refused at the
# existing node boundary before it is ever stored, so serve-hit has
# nothing to ship for it; nothing anywhere the sync touched contains the
# secret's bytes (case T5 below).
# ---------------------------------------------------------------------
mkdir -p "$TMP/secret"
printf 'TOPSECRETVALUE\n' > "$TMP/secret/s.txt"
cat > "$TMP/sealed.pp" <<EOF
force(node { slurp("$TMP/secret/s.txt") })
EOF
HOME="$NODEA" "$PP" --grant "secret:${TMP}/secret" "$TMP/sealed.pp" > "$TMP/out" 2>&1
CODE=$?
assert_exit "T5-sealed-node-refused-exit" 1 "$CODE"
assert "T5-sealed-node-refused-message" "sealed value" present
if grep -rl "TOPSECRETVALUE" "$TMP" --include="*" 2>/dev/null | grep -vE '/secret/s\.txt$' | grep -q .; then
  echo "FAIL T5-no-secret-bytes-anywhere: found outside the source file"
  grep -rl "TOPSECRETVALUE" "$TMP" 2>/dev/null
  fail=1
else
  echo "ok   T5-no-secret-bytes-anywhere"
fi

# ---------------------------------------------------------------------
# Key and result hash are identical whether computed locally or fetched
# via serve-hit: a THIRD, independent, never-synced build of the SAME
# program computes the SAME key filename and byte-identical object (case
# T6 below, partial).
# ---------------------------------------------------------------------
HOME="$NODEC" "$PP" --grant "fs:${WORK}:ro" "$TMP/prog.pp" > "$TMP/out" 2>&1
if [ -f "$NODEC/.pp/store/traces/$KEY" ]; then
  echo "ok   T6-same-key-independent-build"
else
  echo "FAIL T6-same-key-independent-build: missing $KEY in node C"; fail=1
fi
if diff -q "$NODEA/.pp/store/objects/$RESULT_HASH" "$NODEC/.pp/store/objects/$RESULT_HASH" > /dev/null 2>&1; then
  echo "ok   T6-byte-identical-object-independent-build"
else
  echo "FAIL T6-byte-identical-object-independent-build"; fail=1
fi
# The synced-into-B object (recv-hit'd earlier, never itself re-run on B)
# is ALSO byte-identical to A's — the wire path preserves content exactly.
if diff -q "$NODEA/.pp/store/objects/$RESULT_HASH" "$NODEB/.pp/store/objects/$RESULT_HASH" > /dev/null 2>&1; then
  echo "ok   T6-byte-identical-object-via-serve-hit"
else
  echo "FAIL T6-byte-identical-object-via-serve-hit"; fail=1
fi

# A node result may contain a blob reference without reading a file cell.
# Direct serve-hit must transfer that blob too, or the receiving node cannot
# consume the otherwise-valid cached result (follow-up to T6).
BLOB_NODEA="$TMP/blob-nodeA"; BLOB_NODEB="$TMP/blob-nodeB"; BLOB_SHARED="$TMP/blob-shared"
mkdir -p "$BLOB_NODEA" "$BLOB_NODEB"
mkdir -p "$BLOB_NODEA/.pp/cluster" "$BLOB_NODEB/.pp/cluster"
cp "$NODEA/.pp/cluster/secret" "$NODEA/.pp/cluster/id" "$BLOB_NODEA/.pp/cluster/"
cp "$NODEA/.pp/cluster/secret" "$NODEA/.pp/cluster/id" "$BLOB_NODEB/.pp/cluster/"
cat > "$TMP/blob-result.pp" <<'EOF'
let (tree = force(node {
  {:tree -> {"payload" -> {:kind -> :file, :mode -> 420, :blob -> blob("payload")}}}
})) { print(blob-get(tree[:tree]["payload"][:blob])) }
EOF
HOME="$BLOB_NODEA" "$PP" "$TMP/blob-result.pp" > "$TMP/out" 2>&1
assert "result-blob-builds" "payload" present
BLOB_KEY=$(ls "$BLOB_NODEA/.pp/store/traces")
HOME="$BLOB_NODEA" "$PP" --mint-token "$TMP/blob-token.txt" 3600
HOME="$BLOB_NODEA" "$PP" --serve-hit "$BLOB_KEY" "$TMP/blob-token.txt" "$BLOB_SHARED" "$TMP/blob-reply.txt" > "$TMP/out" 2>&1
assert "result-blob-serve-hit" "serve-hit-reply hit" present "$TMP/blob-reply.txt"
BLOB_COUNT=$(find "$BLOB_SHARED/blobs" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$BLOB_COUNT" -ge 1 ]; then echo "ok   result-blob-pushed"
else echo "FAIL result-blob-pushed: expected at least one blob, got $BLOB_COUNT"; fail=1; fi
HOME="$BLOB_NODEB" "$PP" --recv-hit "$TMP/blob-reply.txt" "$BLOB_SHARED" > "$TMP/out" 2>&1
assert "result-blob-recv-hit" "recv-hit: hit" present
HOME="$BLOB_NODEB" "$PP" "$TMP/blob-result.pp" > "$TMP/out" 2>&1
assert "result-blob-consumable-after-sync" "payload" present

exit $fail
