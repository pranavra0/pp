#!/usr/bin/env bash
# A cached result that references a missing blob is not a valid hit: the
# runtime must reject it before serving the value and rebuild the node.
# pins: LAW-16 LAW-17 LAW-19 LAW-18
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PROG="$HOME/blob-cache.pp"
cat >"$PROG" <<'EOF'
let result = force(node {
  perform log("REBUILD")
  {:tree -> {"payload" -> {:kind -> :file, :mode -> 420, :blob -> blob("payload")}}}
})
print(blob-get(result[:tree]["payload"][:blob]))
EOF

"$PP" "$PROG" >"$HOME/first.out" 2>&1
if grep -q '^\[info\] REBUILD$' "$HOME/first.out" && grep -q '^"payload"$' "$HOME/first.out"; then
  ok "missing-blob-initial-build"
else
  bad "missing-blob-initial-build" "$(cat "$HOME/first.out")"
fi

BLOB=$(find "$HOME/.pp/store/blobs" -type f -printf '%f\n' 2>/dev/null | sort | head -n 1)
if [ -z "$BLOB" ]; then
  bad "missing-blob-test-setup" "no blob was persisted" "$(cat "$HOME/first.out")"
else
  rm -f "$HOME/.pp/store/blobs/$BLOB"
  "$PP" "$PROG" >"$HOME/second.out" 2>&1
  if grep -q '^\[info\] REBUILD$' "$HOME/second.out"; then
    ok "missing-blob-rebuilds"
  else
    bad "missing-blob-rebuilds" "$(cat "$HOME/second.out")"
  fi
  if grep -q '^"payload"$' "$HOME/second.out"; then
    ok "missing-blob-rebuild-result"
  else
    bad "missing-blob-rebuild-result" "$(cat "$HOME/second.out")"
  fi
fi

exit "$fail"
