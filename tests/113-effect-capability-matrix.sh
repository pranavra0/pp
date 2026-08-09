#!/usr/bin/env bash
# Every host-facing effect has an explicit authority class and a regression owner.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MATRIX="$ROOT/tests/fixtures/effect-capabilities.tsv"

if ! awk -F '\t' '
  /^[[:space:]]*#/ || NF == 0 { next }
  NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "" {
    print "invalid effect matrix row: " $0 > "/dev/stderr"; bad=1
  }
  seen[$1]++
  END {
    for (name in seen) if (seen[name] != 1) {
      print "duplicate effect matrix row: " name > "/dev/stderr"; bad=1
    }
    exit bad
  }
' "$MATRIX"; then
  bad effect-matrix-shape "invalid rows in $MATRIX"
else
  ok effect-matrix-shape
fi

while IFS=$'\t' read -r operation authority source owner; do
  case "$operation" in ''|'#'*) continue ;; esac
  [ -f "$ROOT/$source" ] || bad "matrix-source-$operation" "missing $source"
  [ -f "$ROOT/$owner" ] || bad "matrix-owner-$operation" "missing $owner"
done < "$MATRIX"

awk '
  /^  \| "[^"]+"/ {
    line=$0; sub(/^  \| "/, "", line); sub(/".*/, "", line); print line
  }
' "$ROOT/src/runtime/evaluator_effects.ml" | sort -u > "$TMP/actual-effects"
awk -F '\t' '$1 ~ /^perform:/ { sub(/^perform:/, "", $1); print $1 }' \
  "$MATRIX" | sort -u > "$TMP/matrix-effects"
if diff -u "$TMP/actual-effects" "$TMP/matrix-effects" > "$TMP/effect-diff"; then
  ok effect-dispatch-complete
else
  bad effect-dispatch-complete "$(cat "$TMP/effect-diff")"
fi

cat > "$TMP/domain-state.pp" <<'EOF'
perform domain-state-get("key")
EOF
"$PP" "$TMP/domain-state.pp" > "$TMP/domain-state.out" 2>&1
status=$?
if [ "$status" -eq 1 ] && grep -q "not running inside a domain" "$TMP/domain-state.out"; then
  ok domain-state-context-gated
else
  bad domain-state-context-gated "status=$status: $(cat "$TMP/domain-state.out")"
fi

if [ "$fail" -eq 0 ]; then echo "=== EFFECT CAPABILITY MATRIX TEST PASSED ==="; fi
exit "$fail"
