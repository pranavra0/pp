#!/usr/bin/env bash
# Semantic JSONL recording explains cold rebuilds, invalidation, and warm verified hits without changing program output.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

assert() {
  local name=$1 pattern=$2 presence=$3 file=$4
  if grep -qE "$pattern" "$file"; then
    [ "$presence" = present ] && ok "$name" || bad "$name" "unexpected: $pattern"
  else
    [ "$presence" = absent ] && ok "$name" || bad "$name" "missing: $pattern"
  fi
}

mkdir -p "$HOME/work"
PROGRAM="$HOME/work/build.pp"
cat > "$PROGRAM" <<'PP'
let built = force(node { 40 + 2 })
print(built)
PP

store_manifest() {
  local root=$1
  if [ -d "$root/.pp/store" ]; then
    (cd "$root/.pp/store" && find . -type f ! -path './locks/*' -print0 | sort -z | xargs -0 sha256sum)
  fi
}

PLAIN_HOME="$TMP/plain-home"
RECORDED_HOME="$TMP/recorded-home"
mkdir -p "$PLAIN_HOME" "$RECORDED_HOME"
HOME="$PLAIN_HOME" "$PP" "$PROGRAM" > "$TMP/plain.out" 2> "$TMP/plain.err"
store_manifest "$PLAIN_HOME" > "$TMP/plain.store"
HOME="$RECORDED_HOME" "$PP" simulate --record "$TMP/cold.jsonl" "$PROGRAM" > "$TMP/cold.out" 2> "$TMP/cold.err"
store_manifest "$RECORDED_HOME" > "$TMP/cold.store"
cmp "$TMP/plain.store" "$TMP/cold.store"
export HOME="$RECORDED_HOME"
"$PP" simulate --record "$TMP/warm.jsonl" "$PROGRAM" > "$TMP/warm.out" 2> "$TMP/warm.err"
export HOME="$TMP"

cmp "$TMP/plain.out" "$TMP/cold.out"
cmp "$TMP/plain.err" "$TMP/cold.err"
cmp "$TMP/plain.out" "$TMP/warm.out"
cmp "$TMP/plain.err" "$TMP/warm.err"

assert "cold-run-created" '"kind":"run.created"' present "$TMP/cold.jsonl"
assert "cold-source-read" '"kind":"source.read".*"content_hash":"[0-9a-f]{64}"' present "$TMP/cold.jsonl"
assert "cold-source-parsed" '"kind":"source.parsed".*"form_count":2' present "$TMP/cold.jsonl"
assert "cold-source-expanded" '"kind":"source.macro_expanded"' present "$TMP/cold.jsonl"
assert "cold-cache-miss" '"kind":"cache.miss".*"reason":"no_stored_trace"' present "$TMP/cold.jsonl"
assert "cold-node-identity" '"kind":"identity.node_key.computed".*"node_key":"[0-9a-f]{64}"' present "$TMP/cold.jsonl"
assert "cold-result-identity" '"kind":"identity.result_hash.computed".*"result_hash":"[0-9a-f]{64}"' present "$TMP/cold.jsonl"
assert "cold-rebuild-started" '"kind":"node.rebuild","phase":"started"' present "$TMP/cold.jsonl"
assert "cold-rebuild-finished" '"kind":"node.rebuild","phase":"finished"' present "$TMP/cold.jsonl"
assert "cold-object-persisted" '"kind":"store.object.persisted".*"result_hash":"[0-9a-f]{64}"' present "$TMP/cold.jsonl"
assert "cold-trace-persisted" '"kind":"store.trace.persisted".*"outcome":"ok"' present "$TMP/cold.jsonl"
assert "cold-run-finished" '"kind":"run.finished"' present "$TMP/cold.jsonl"
assert "warm-cache-hit" '"kind":"cache.hit"' present "$TMP/warm.jsonl"
assert "warm-trace-verified" '"kind":"cache.trace.considered".*"status":"usable"' present "$TMP/warm.jsonl"
assert "warm-no-rebuild" '"kind":"node.rebuild"' absent "$TMP/warm.jsonl"
assert "recording-no-source-path" "$PROGRAM" absent "$TMP/cold.jsonl"
"$PP" simulate --event-level summary --record "$TMP/summary.jsonl" \
  "$PROGRAM" > /dev/null
assert "summary-has-run" '"category":"run"' present "$TMP/summary.jsonl"
assert "summary-omits-semantic" '"category":"(source|cache|node)"' absent "$TMP/summary.jsonl"

cat > "$HOME/work/input.txt" <<'EOF'
one
EOF
cat > "$HOME/work/observed.pp" <<PP
print(force(node { slurp("$HOME/work/input.txt") }))
PP
"$PP" --grant "fs:$HOME/work:ro" "$HOME/work/observed.pp" > /dev/null
printf 'two\n' > "$HOME/work/input.txt"
"$PP" simulate --record "$TMP/stale.jsonl" \
  --grant "fs:$HOME/work:ro" "$HOME/work/observed.pp" > /dev/null
assert "stale-trace-event" '"kind":"cache.trace.considered".*"status":"stale"' present "$TMP/stale.jsonl"
assert "stale-cache-miss" '"kind":"cache.miss".*"reason":"no_usable_trace"' present "$TMP/stale.jsonl"
assert "stale-rebuild" '"kind":"node.rebuild","phase":"finished"' present "$TMP/stale.jsonl"

printf 'unknown-name\n' > "$TMP/bad.pp"
set +e
"$PP" "$TMP/bad.pp" > "$TMP/failed-plain.out" 2> "$TMP/failed-plain.err"
plain_status=$?
"$PP" simulate --record "$TMP/failed.jsonl" "$TMP/bad.pp" > "$TMP/failed-recorded.out" 2> "$TMP/failed-recorded.err"
recorded_status=$?
set -e
cmp "$TMP/failed-plain.out" "$TMP/failed-recorded.out"
cmp "$TMP/failed-plain.err" "$TMP/failed-recorded.err"
if [ "$plain_status" -eq "$recorded_status" ] && [ "$recorded_status" -ne 0 ]; then
  ok "failed-run-exit"
else
  bad "failed-run-exit" "invalid program unexpectedly succeeded"
fi
assert "failed-run-event" '"kind":"run.failed"' present "$TMP/failed.jsonl"
assert "failed-run-not-finished" '"kind":"run.finished"' absent "$TMP/failed.jsonl"
assert "failed-run-redacts-message" 'unknown-name' absent "$TMP/failed.jsonl"

printf 'let broken = {\n' > "$TMP/malformed.pp"
if "$PP" simulate --record "$TMP/malformed.jsonl" "$TMP/malformed.pp" > /dev/null 2>&1; then
  bad "malformed-run-exit" "malformed program unexpectedly succeeded"
else
  ok "malformed-run-exit"
fi
assert "source-error-event" '"kind":"source.error".*"stage":"parse"' present "$TMP/malformed.jsonl"

mkdir -p "$HOME/private"
printf 'SECRET-CONTENT\n' > "$HOME/private/secret-name.txt"
cat > "$TMP/secret.pp" <<PP
force(node { slurp("$HOME/private/secret-name.txt") })
PP
rm -rf "$HOME/.pp"
"$PP" --grant "fs:$HOME:ro" "$TMP/secret.pp" > /dev/null
if "$PP" simulate --record "$TMP/redacted.jsonl" \
    --grant "fs:$HOME/work:ro" "$TMP/secret.pp" > /dev/null 2>&1; then
  bad "unauthorized-run-exit" "unauthorized run unexpectedly succeeded"
else
  ok "unauthorized-run-exit"
fi
assert "unauthorized-event" '"status":"unauthorized","cell_id":null' present "$TMP/redacted.jsonl"
assert "unauthorized-visibility" '"visibility":"redacted"' present "$TMP/redacted.jsonl"
assert "unauthorized-no-path" 'secret-name' absent "$TMP/redacted.jsonl"
assert "unauthorized-no-bytes" 'SECRET-CONTENT' absent "$TMP/redacted.jsonl"

for level in summary semantic evaluation transport; do
  if "$PP" simulate --event-level "$level" --record "$TMP/redacted-$level.jsonl" \
      --grant "fs:$HOME/work/RAW-TOKEN-MARKER:ro" "$TMP/secret.pp" > /dev/null 2>&1; then
    bad "redaction-$level-exit" "unauthorized run unexpectedly succeeded"
  fi
  assert "redaction-$level-path" 'secret-name' absent "$TMP/redacted-$level.jsonl"
  assert "redaction-$level-bytes" 'SECRET-CONTENT' absent "$TMP/redacted-$level.jsonl"
  assert "redaction-$level-token" 'RAW-TOKEN-MARKER' absent "$TMP/redacted-$level.jsonl"
done

event_count=$(wc -l < "$TMP/cold.jsonl")
event_bytes=$(wc -c < "$TMP/cold.jsonl")
[ "$event_count" -le 32 ] || bad "bounded-event-count" "cold build recorded $event_count events"
[ "$event_bytes" -le $((event_count * 1024)) ] \
  && ok "bounded-recording-bytes" \
  || bad "bounded-recording-bytes" "$event_bytes bytes for $event_count events"

event_ids=$(sed -n 's/.*"event_id":\([0-9][0-9]*\).*/\1/p' "$TMP/cold.jsonl")
expected_ids=$(seq 1 "$(wc -l < "$TMP/cold.jsonl")")
[ "$event_ids" = "$expected_ids" ] || {
  echo "FAIL event ids are not contiguous" >&2
  exit 1
}

echo "=== SIMULATOR EVENT TEST PASSED ==="
exit "$fail"
