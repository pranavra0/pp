#!/usr/bin/env bash
# tests/088 — with-config rejects non-map values on both source surfaces,
# preserving the runtime error, source location, and exit status.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/brace.pp" <<'EOF'
with-config(5) { print("unreachable") }
EOF
cat > "$TMP/sexpr.ppl" <<'EOF'
(with-config 5 (print "unreachable"))
EOF

run_case() {
  local name="$1" file="$2" err="$TMP/$1.err" out="$TMP/$1.out" ec=0
  "$PP" "$file" >"$out" 2>"$err" || ec=$?
  if [ "$ec" -eq 1 ] && [ ! -s "$out" ] \
      && grep -qE '^pp: error: with-config expects a map at .*\.(pp|ppl):1$' "$err" \
      && ! grep -q 'Fatal error' "$err"; then
    ok "$name"
  else
    bad "$name" "exit=$ec" "stdout: $(cat "$out")" "stderr: $(cat "$err")"
  fi
}

run_case "brace-with-config-non-map" "$TMP/brace.pp"
run_case "sexpr-with-config-non-map" "$TMP/sexpr.ppl"

brace_err=$(sed -E 's#(brace\.pp|sexpr\.ppl):1#surface:1#' "$TMP/brace-with-config-non-map.err")
sexpr_err=$(sed -E 's#(brace\.pp|sexpr\.ppl):1#surface:1#' "$TMP/sexpr-with-config-non-map.err")
if [ "$brace_err" = "$sexpr_err" ]; then
  ok "with-config-error-surface-parity"
else
  bad "with-config-error-surface-parity" "brace: $brace_err" "sexpr: $sexpr_err"
fi

rm -rf "$TMP"
exit $fail
