#!/usr/bin/env bash
# tests/117-single-record.sh — events take exactly one recording path.
# dynamic-scope dispatches through the :record-event service alone; a second
# append (direct push plus service, the old dual path) would duplicate the
# event inside the reporter vector, so event-recorded-once fails there.
#
# Honest limits: the --dump-pins assertion is a smoke pin, not a
# discriminator — %command-dump-pins keys its output by serialized cell
# text, so double-recorded reads collapse to one line. Read multiplicity
# reaches no other CLI surface (the reporter sees events, not reads).
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/single.pp" <<'EOF'
load("stdlib/runtime.pp")
configure-runtime({:reporter -> reporter-console})
emit-event({:kind -> :single-record, :value -> "once"})
$env("PP117_SINGLE_RECORD")
EOF

"$PP" "$TMP/single.pp" > "$TMP/run.out" 2>&1
code=$?
if [ "$code" -eq 0 ]; then
  ok "run-exits-zero"
else
  bad "run-exits-zero" "exit=$code" "$(cat "$TMP/run.out")"
fi

# The reporter receives the event vector; double-append shows up as a
# duplicated event inside the printed vector.
events=$(grep -o 'single-record' "$TMP/run.out" | wc -l)
if [ "$events" -eq 1 ]; then
  ok "event-recorded-once"
else
  bad "event-recorded-once" "expected 1 recorded event, got $events" \
    "$(cat "$TMP/run.out")"
fi
"$PP" --dump-pins "$TMP/pins.txt" "$TMP/single.pp" > "$TMP/pins.out" 2>&1
code=$?
if [ "$code" -eq 0 ]; then
  ok "dump-pins-exits-zero"
else
  bad "dump-pins-exits-zero" "exit=$code" "$(cat "$TMP/pins.out")"
fi

# The env read reaches the pin dump as exactly one recorded observation.
assert_count read-recorded-once 'pin "env:PP117_SINGLE_RECORD"' 1 "$TMP/pins.txt"

exit "$fail"
