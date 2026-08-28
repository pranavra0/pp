#!/usr/bin/env bash
# A cacheable durable node result can cross the hash-checked transport boundary.
# This deliberately does not claim transport reuse for scripting-only
# run-closed! results: the producer below is a persistent node whose result is
# durable and whose trace closure is revalidated in the receiving store.
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

assert_exit() {  # NAME EXPECTED ACTUAL
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then echo "ok   $name"
  else echo "FAIL $name: expected exit $expected, got $actual"; fail=1; fi
}

WORK="$TMP/work"; NODEA="$TMP/node-a"; NODEB="$TMP/node-b"
SHARED="$TMP/shared"; REPLY="$TMP/reply.txt"; TOKEN="$TMP/token.txt"
mkdir -p "$WORK" "$NODEA" "$NODEB"
printf 'TRANSPORT-V1\n' > "$WORK/input.txt"

cat > "$TMP/producer.pp" <<EOF
perform log(force(node {
  perform log("PRODUCER-RAN")
  slurp("$WORK/input.txt")
}))
EOF

# Producer A computes and persists a durable node result and its verifying trace.
HOME="$NODEA" "$PP" --grant "fs:$WORK:ro" "$TMP/producer.pp" > "$TMP/a.out" 2>&1
assert "producer-computed" "PRODUCER-RAN" present "$TMP/a.out"
assert "producer-result" "TRANSPORT-V1" present "$TMP/a.out"
KEY=$(ls "$NODEA/.pp/store/traces" 2>/dev/null | head -n 1)
RESULT_HASH=$(grep -oE '"[0-9a-f]{64}"' "$NODEA/.pp/store/traces/$KEY" 2>/dev/null | head -n 1 | tr -d '"')
if [ -n "$KEY" ] && [ -n "$RESULT_HASH" ]; then
  echo "ok   producer-descriptor-identities"
else
  echo "FAIL producer-descriptor-identities: missing key/result hash"; fail=1
fi

# A's signed descriptor is copied through serve-hit's hash-checked artifact
# transport. B starts with no store artifacts of its own.
HOME="$NODEA" "$PP" cluster-init > /dev/null 2>&1
HOME="$NODEA" "$PP" --grant "fs:$WORK:ro" --mint-token "$TOKEN" 3600 > /dev/null 2>&1
HOME="$NODEA" "$PP" --serve-hit "$KEY" "$TOKEN" "$SHARED" "$REPLY" > "$TMP/serve.out" 2>&1
assert "transport-descriptor-hit" "serve-hit-reply hit" present "$REPLY"
assert "transport-descriptor-result" "$RESULT_HASH" present "$REPLY"
if [ -d "$NODEB/.pp/store/objects" ] && [ "$(find "$NODEB/.pp/store/objects" -type f 2>/dev/null | wc -l | tr -d ' ')" -ne 0 ]; then
  echo "FAIL fresh-store-before-receive: B already has objects"; fail=1
else
  echo "ok   fresh-store-before-receive"
fi

HOME="$NODEB" "$PP" --recv-hit "$REPLY" "$SHARED" > "$TMP/recv.out" 2>&1
CODE=$?
assert_exit "transport-receive-exit" 0 "$CODE"
assert "transport-receive-hit" "recv-hit: hit" present "$TMP/recv.out"
if [ -f "$NODEB/.pp/store/objects/$RESULT_HASH" ] && [ -f "$NODEB/.pp/store/traces/$KEY" ]; then
  echo "ok   transported-result-and-trace-present"
else
  echo "FAIL transported-result-and-trace-present"; fail=1
fi

# The receiving force reuses the transported durable result. The producer
# marker must stay absent while the result remains visible.
HOME="$NODEB" "$PP" why --grant "fs:$WORK:ro" "$TMP/producer.pp" > "$TMP/b.out" 2>&1
CODE=$?
assert_exit "reuse-exit" 0 "$CODE"
assert "reuse-cache-hit" "\[why\].*hit" present "$TMP/b.out"
assert "reuse-no-producer" "PRODUCER-RAN" absent "$TMP/b.out"
assert "reuse-result" "TRANSPORT-V1" present "$TMP/b.out"

if [ "$fail" -eq 0 ]; then echo "=== TRANSPORTED RESULT REUSE TEST PASSED ==="; fi
exit "$fail"
