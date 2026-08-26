#!/usr/bin/env bash
# Process-domain reconcile convergence through the CLI.
#
#   The reconcile pass must genuinely observe -> diff -> apply -> verify:
#     - a first `pp --supervise` pass starts the services;
#     - a second pass re-observes, produces an EMPTY struct plan
#       (started=0 stopped=0 restarted=0) and verify-after-write accepts it
#       (exit 0) instead of skipping verification for non-value-map plans;
#     - after a service is killed with kill -9, observation (the per-record
#       reap inside observe) notices the dead pid without any config edit and
#       exactly that service is restarted; the following pass converges again.
#
#   The diff itself needs no authority and runs under an empty capability set.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

wait_for() {  # SECONDS CMD ARGS...
  local secs="$1"; shift
  local i=0 max=$((secs * 10))
  while [ "$i" -lt "$max" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.1; i=$(( i + 1 ))
  done
  "$@" >/dev/null 2>&1
}

cleanup_services() {
  for pidfile in "$TMP"/pid-*; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null) || continue
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}

# Long-running service: writes its PID to arg $1 and sleeps.
mkdir -p "$TMP/svc"
cat > "$TMP/svc/run.sh" <<'EOF'
#!/bin/sh
echo $$ > "$1"
exec sleep 1000
EOF
chmod +x "$TMP/svc/run.sh"

cat > "$TMP/supervise.pp" <<EOF
{"svc-a" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-a"], "cwd" -> "$TMP", "env" -> {"MARKER" -> "a"}}, "svc-b" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-b"], "cwd" -> "$TMP", "env" -> {"MARKER" -> "b"}}}
EOF

GRANT="--grant process"

# --- (a) first pass starts both services ---
rm -rf "$TMP/.pp"
"$PP" --supervise $GRANT "$TMP/supervise.pp" > "$TMP/out" 2>&1
code=$?
if [ "$code" -eq 0 ]; then echo "ok   first-pass-exit"; \
else bad "first-pass-exit" "exit=$code" "$(cat "$TMP/out")"; fi
assert "first-pass-started" 'started=' present
wait_for 5 test -f "$TMP/pid-a" || { echo "FAIL first-pass-pid-a"; fail=1; }
wait_for 5 test -f "$TMP/pid-b" || { echo "FAIL first-pass-pid-b"; fail=1; }

# --- (b) second pass observes convergence: empty plan, verify accepts it ---
"$PP" --supervise $GRANT "$TMP/supervise.pp" > "$TMP/out2" 2>&1
code=$?
if [ "$code" -eq 0 ]; then echo "ok   converge-exit"; \
else bad "converge-exit" "verify-after-write or other failure, exit=$code" "$(cat "$TMP/out2")"; fi
grep -q 'started=0' "$TMP/out2" && grep -q 'stopped=0' "$TMP/out2" && grep -q 'restarted=0' "$TMP/out2" \
  && ok "converge-empty-plan" || bad "converge-empty-plan" "plan not empty" "$(cat "$TMP/out2")"
PID_A=$(cat "$TMP/pid-a")
kill -0 "$PID_A" 2>/dev/null && ok "converge-no-spurious-restart" \
  || bad "converge-no-spurious-restart" "pid $PID_A died across no-op pass"

# --- (c) drift by kill -9: observation reaps the dead pid, diff restarts one ---
kill -9 "$PID_A" 2>/dev/null || true
"$PP" --supervise $GRANT "$TMP/supervise.pp" > "$TMP/out3" 2>&1
code=$?
if [ "$code" -eq 0 ]; then echo "ok   restart-exit"; \
else bad "restart-exit" "exit=$code" "$(cat "$TMP/out3")"; fi
assert "restart-summary" 'restarted=1' present "$TMP/out3"
wait_for 5 test -f "$TMP/pid-a" || { echo "FAIL restart-pid-a"; fail=1; }
NEW_A=$(cat "$TMP/pid-a")
[ -n "$NEW_A" ] && [ "$NEW_A" != "$PID_A" ] && kill -0 "$NEW_A" 2>/dev/null \
  && ok "restart-new-pid-alive" \
  || bad "restart-new-pid-alive" "old=$PID_A new=$NEW_A"
# svc-b was untouched: still the same live pid.
kill -0 "$(cat "$TMP/pid-b")" 2>/dev/null && ok "drift-scoped-to-dead-service" \
  || bad "drift-scoped-to-dead-service" "healthy svc-b restarted"
# --- (d) post-restart pass converges again ---
"$PP" --supervise $GRANT "$TMP/supervise.pp" > "$TMP/out4" 2>&1
code=$?
if [ "$code" -eq 0 ]; then echo "ok   reconverge-exit"; \
else bad "reconverge-exit" "exit=$code" "$(cat "$TMP/out4")"; fi


# --- (e) deliberately under-converging service: verify-after-write must ---
# --- fail loudly instead of silently skipping verification for struct   ---
# --- plans.  The service dies immediately, so the post-apply re-diff    ---
# --- still has a restart pending and reconcile must exit non-zero.      ---
cat > "$TMP/svc/die.sh" <<'EOF'
#!/bin/sh
echo $$ > "$1"
exit 0
EOF
chmod +x "$TMP/svc/die.sh"
cat > "$TMP/supervise-die.pp" <<EOF
{"svc-die" -> {"cmd" -> "$TMP/svc/die.sh", "args" -> ["$TMP/pid-die"], "cwd" -> "$TMP", "env" -> {"MARKER" -> "die"}}}
EOF
"$PP" --supervise $GRANT "$TMP/supervise-die.pp" > "$TMP/out5" 2>&1
code=$?
if [ "$code" -ne 0 ] && grep -q 'verify-after-write failed' "$TMP/out5"; then
  ok "underconverged-verify-fails"
else
  bad "underconverged-verify-fails" "exit=$code" "$(cat "$TMP/out5")"
fi

cleanup_services
exit "$fail"
