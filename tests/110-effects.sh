#!/usr/bin/env bash
# Bang-suffixed effects are strict ordinary values, and mutators have one spelling.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run_pp() { "$PP" "$@" >"$TMP/out" 2>&1; }

cat > "$TMP/higher-order.pp" <<'PP'
with-handler(log! = fn(message) {
  print(string-append("handled:", message))
}) {
  let emit = log!
  emit("value")
}
PP
run_pp "$TMP/higher-order.pp"
if grep -q '^"handled:value"$' "$TMP/out"; then ok "effect-value-handler"
else bad "effect-value-handler" "$(cat "$TMP/out")"; fi

cat > "$TMP/shadow.pp" <<'PP'
let log! = fn(message) { print(string-append("shadow:", message)) }
log!("value")
PP
run_pp "$TMP/shadow.pp"
if grep -q '^"shadow:value"$' "$TMP/out"; then ok "effect-value-shadowing"
else bad "effect-value-shadowing" "$(cat "$TMP/out")"; fi

cat > "$TMP/mutators.pp" <<'PP'
load("stdlib/list.pp")
load("stdlib/runtime.pp")
configure-runtime!({:schedule -> schedule-serial()})
emit-event!({:kind -> :effects-test})
each!(fn(x) { print(x) }, list(1, 2))
PP
run_pp "$TMP/mutators.pp"
if [ "$?" -eq 0 ] && grep -q '^1$' "$TMP/out" && grep -q '^2$' "$TMP/out"; then
  ok "bang-mutators"
else
  bad "bang-mutators" "$(cat "$TMP/out")"
fi

for name in log run write-file configure-runtime register-domain register-probe; do
  run_pp -e "$name(\"x\")"
  if grep -q "unbound symbol: $name" "$TMP/out"; then ok "old-$name-removed"
  else bad "old-$name-removed" "$(cat "$TMP/out")"; fi
done

rm -rf "$TMP"
exit "$fail"
