#!/usr/bin/env bash
# Fork-at-dispatch store stress and dynamic-scope inheritance.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/stress.pp" <<'EOF'
def int-range(a, b) { if a >= b { nil } else { cons(a, int-range(a + 1, b)) } }
def sum-list(xs) { if nil?(xs) { 0 } else { car(xs) + sum-list(cdr(xs)) } }
def make(i) { node { i } }
print(sum-list(force-deep(map(make, int-range(0, 64)))))
EOF

for iteration in 1 2 3 4 5; do
  rm -rf "$TMP/.pp"
  out=$("$PP" --schedule parallel:16 "$TMP/stress.pp" 2>"$TMP/stress.err")
  traces=$(find "$TMP/.pp/store/traces" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "$out" = 2016 ] && [ "$traces" -eq 64 ]; then
    ok "parallel-store-$iteration"
  else
    bad "parallel-store-$iteration" "result=$out traces=$traces" "$(cat "$TMP/stress.err")"
  fi
done

cat > "$TMP/one-key.pp" <<'EOF'
def one() { force(node { 99 }) }
print(one())
EOF
rm -rf "$TMP/.pp"
out=$(PP_TRACE_LOCK=0 "$PP" --schedule race:8 "$TMP/one-key.pp" 2>"$TMP/one-key.err")
trace=$(find "$TMP/.pp/store/traces" -type f 2>/dev/null | head -1)
if [ "$out" = 99 ] && grep -qE '^\(trace (ok|failed) ' "$trace"; then
  ok "unlocked-same-key-trace"
else
  bad "unlocked-same-key-trace" "result=$out" "$(cat "$TMP/one-key.err")"
fi

cat > "$TMP/inherited.pp" <<'EOF'
def int-range(a, b) { if a >= b { nil } else { cons(a, int-range(a + 1, b)) } }
def sum-list(xs) { if nil?(xs) { 0 } else { car(xs) + sum-list(cdr(xs)) } }
def make(i) { node { perform ask(i) + $config("offset") } }
with {
  config: { :offset -> 10 },
  handlers: { :ask -> fn(n) { n + 1 } }
} {
  print(sum-list(force-deep(map(make, int-range(1, 3)))))
}
EOF
out=$("$PP" --schedule parallel:2 "$TMP/inherited.pp" 2>"$TMP/inherited.err")
if [ "$out" = 25 ]; then ok "parallel-inherits-session"
else bad "parallel-inherits-session" "result=$out" "$(cat "$TMP/inherited.err")"; fi

cat > "$TMP/fenced.pp" <<'EOF'
force(node { fenced("x", {}); 1 })
EOF
for schedule in parallel:4 race:3; do
  "$PP" --schedule "$schedule" "$TMP/fenced.pp" >"$TMP/fenced.out" 2>&1
  if grep -q "fenced effects may not appear inside node bodies" "$TMP/fenced.out"; then
    ok "fenced-denied-$schedule"
  else
    bad "fenced-denied-$schedule" "$(cat "$TMP/fenced.out")"
  fi
done

rm -rf "$TMP"
exit "$fail"
