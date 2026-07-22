#!/usr/bin/env bash
# Semantic JSONL recording explains cold rebuilds, invalidation, and warm verified hits with structural redaction.
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

rm -rf "$HOME/.pp"
"$PP" simulate --record "$TMP/cold.jsonl" "$PROGRAM" > "$TMP/cold.out" 2> "$TMP/cold.err"
"$PP" simulate --record "$TMP/warm.jsonl" "$PROGRAM" > "$TMP/warm.out" 2> "$TMP/warm.err"

assert "cold-run-created" '"kind":"run.created"' present "$TMP/cold.jsonl"
assert "cold-run-configured" '"kind":"run.configured".*"event_level":"semantic"' present "$TMP/cold.jsonl"
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

cold_node_key=$(sed -n '/"kind":"identity.node_key.computed"/s/.*"node_key":"\([^"]*\)".*/\1/p' "$TMP/cold.jsonl")
cold_cache_key=$(sed -n '/"kind":"cache.miss"/s/.*"cache_key":"\([^"]*\)".*/\1/p' "$TMP/cold.jsonl")
cold_rebuild_key=$(sed -n '/"kind":"node.rebuild","phase":"started"/s/.*"node_key":"\([^"]*\)".*/\1/p' "$TMP/cold.jsonl")
if [ "$cold_node_key" = "$cold_cache_key" ] && [ "$cold_node_key" = "$cold_rebuild_key" ]; then
  ok "cold-identity-chain"
else
  bad "cold-identity-chain" "node, cache, and rebuild keys differ"
fi
cold_result_hash=$(sed -n '/"kind":"identity.result_hash.computed"/s/.*"result_hash":"\([^"]*\)".*/\1/p' "$TMP/cold.jsonl")
warm_result_hash=$(sed -n '/"kind":"cache.hit"/s/.*"result_hash":"\([^"]*\)".*/\1/p' "$TMP/warm.jsonl")
persisted_hashes=$(sed -n '/"kind":"store\..*persisted"/s/.*"result_hash":"\([^"]*\)".*/\1/p' "$TMP/cold.jsonl" | sort -u)
if [ "$cold_result_hash" = "$warm_result_hash" ] && [ "$cold_result_hash" = "$persisted_hashes" ]; then
  ok "result-persistence-chain"
else
  bad "result-persistence-chain" "computed, persisted, and hit result hashes differ"
fi
rebuild_start_id=$(sed -n '/"kind":"node.rebuild","phase":"started"/s/.*"event_id":\([0-9]*\).*/\1/p' "$TMP/cold.jsonl")
rebuild_parent_id=$(sed -n '/"kind":"node.rebuild","phase":"finished"/s/.*"parent_event_id":\([0-9]*\).*/\1/p' "$TMP/cold.jsonl")
[ "$rebuild_start_id" = "$rebuild_parent_id" ] \
  && ok "rebuild-causality" \
  || bad "rebuild-causality" "finished rebuild does not name its start"
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
assert "stale-object-persisted" '"kind":"store.object.persisted"' present "$TMP/stale.jsonl"
assert "stale-trace-persisted" '"kind":"store.trace.persisted"' present "$TMP/stale.jsonl"

cat > "$TMP/node-failure.pp" <<'PP'
force(node { missing_value })
PP
for run in cold warm; do
  if "$PP" simulate --record "$TMP/failure-$run.jsonl" "$TMP/node-failure.pp" \
      > /dev/null 2>&1; then
    bad "failure-$run-exit" "failing node unexpectedly succeeded"
  else
    ok "failure-$run-exit"
  fi
done
assert "failure-cold-miss" '"kind":"cache.miss".*"reason":"no_stored_trace"' present "$TMP/failure-cold.jsonl"
assert "failure-cold-persisted" '"kind":"store.trace.persisted".*"outcome":"failed"' present "$TMP/failure-cold.jsonl"
assert "failure-cold-rebuild" '"kind":"node.rebuild","phase":"failed"' present "$TMP/failure-cold.jsonl"
assert "failure-warm-replayed" '"kind":"cache.hit".*"outcome":"failed"' present "$TMP/failure-warm.jsonl"
assert "failure-warm-no-rebuild" '"kind":"node.rebuild"' absent "$TMP/failure-warm.jsonl"

printf 'unknown-name\n' > "$TMP/bad.pp"
if "$PP" simulate --record "$TMP/failed.jsonl" "$TMP/bad.pp" > /dev/null 2>&1; then
  bad "failed-run-exit" "invalid program unexpectedly succeeded"
else
  ok "failed-run-exit"
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

event_ids=$(sed -n 's/.*"event_id":\([0-9][0-9]*\).*/\1/p' "$TMP/cold.jsonl")
expected_ids=$(seq 1 "$(wc -l < "$TMP/cold.jsonl")")
[ "$event_ids" = "$expected_ids" ] || {
  echo "FAIL event ids are not contiguous" >&2
  exit 1
}

echo "=== SIMULATOR EVENT TEST PASSED ==="
exit "$fail"
