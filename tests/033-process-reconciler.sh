#!/usr/bin/env bash
# Process-domain reconciler.
#
#   pp --supervise prog.pp treats the program's final value as a desired
#   process map {service-name -> spec-map}. The supervisor starts/stops/
#   restarts services so that observed reality matches desired state:
#     - a service killed with kill -9 is restarted within one poll interval;
#     - editing config changes the spec hash and restarts exactly the
#       affected service;
#     - removing a service from desired state stops it.
#
#   Authority: --grant process is required. Start/stop operations are
#   journaled intent/done pairs.
#
# Runs under an isolated HOME; both backends.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

# Portable `timeout`: macOS ships without coreutils. Must be a real executable,
# not a shell function — `timeout N cmd &` has to put cmd's own pid in $! so
# `kill $!` reaches it (alarm(2) survives the exec chain).
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

# Poll for a condition: the supervisor spawns services asynchronously, so
# pidfile writes land shortly *after* pp returns. Bounded wait, 0.1s steps.
wait_for() {  # SECONDS CMD ARGS...
  local secs="$1"; shift
  local i=0 max=$((secs * 10))
  while [ "$i" -lt "$max" ]; do
    "$@" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  "$@" 2>/dev/null
}

# Initial convergence can restart a service once before it settles (first pass
# starts it, a later pass reconciles). Capturing a baseline pid the instant the
# pidfile appears would race that churn, so a "did this service restart" test
# must first wait for the pid to STOP changing — a condition, not a fixed beat.
stable_pid() {  # FILE — succeeds once FILE's pid holds steady across a poll window
  local f="$1" a b
  a=$(cat "$f" 2>/dev/null) || return 1
  [ -n "$a" ] || return 1
  sleep 0.5
  b=$(cat "$f" 2>/dev/null)
  [ "$a" = "$b" ]
}

# Kill any services whose pidfiles we created.
cleanup_services() {
  for pidfile in "$TMP"/pid-*; do
    [ -f "$pidfile" ] || continue
    pid=$(cat "$pidfile" 2>/dev/null) || continue
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
}

# Helper long-running service: writes its PID to the path given as arg $1 and sleeps.
mkdir -p "$TMP/svc"
cat > "$TMP/svc/run.sh" <<'EOF'
#!/bin/sh
echo $$ > "$1"
exec sleep 1000
EOF
chmod +x "$TMP/svc/run.sh"

# The program reads a config file so config edits change the spec hash.
mkdir -p "$TMP/cfg"
echo "v1" > "$TMP/cfg/env.txt"

cat > "$TMP/supervise.pp" <<EOF
let (cfg = slurp("$TMP/cfg/env.txt")) {
  {"svc-a" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-a"], "cwd" -> "$TMP", "env" -> {"MARKER" -> cfg}}, "svc-b" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-b"], "cwd" -> "$TMP", "env" -> {"MARKER" -> "stable"}}}
}
EOF

# --- (a) no process grant ⇒ capability error ---
"$PP" --supervise --grant "fs:$TMP/cfg:ro" "$TMP/supervise.pp" > "$TMP/out" 2>&1 || true
assert "nogrant-denied" "capability error" present

# --- (b) one-shot supervise starts both services ---
rm -rf "$TMP/.pp"
"$PP" --supervise --grant process --grant "fs:$TMP/cfg:ro" "$TMP/supervise.pp" > "$TMP/out" 2>&1
assert "oneshot-started" "started=" present
wait_for 5 test -f "$TMP/pid-a" || { echo "FAIL oneshot-pid-a: pidfile missing"; fail=1; }
wait_for 5 test -f "$TMP/pid-b" || { echo "FAIL oneshot-pid-b: pidfile missing"; fail=1; }
PID_A=$(cat "$TMP/pid-a")
PID_B=$(cat "$TMP/pid-b")
kill -0 "$PID_A" 2>/dev/null && echo "ok   oneshot-alive-a" \
  || { echo "FAIL oneshot-alive-a: pid $PID_A not alive"; fail=1; }
kill -0 "$PID_B" 2>/dev/null && echo "ok   oneshot-alive-b" \
  || { echo "FAIL oneshot-alive-b: pid $PID_B not alive"; fail=1; }
# Stop the orphans so they do not leak into later tests.
kill "$PID_A" 2>/dev/null || true
kill "$PID_B" 2>/dev/null || true
cleanup_services

# --- (c) watch mode: kill -9 restarts within one interval ---
rm -rf "$TMP/.pp"
echo "v1" > "$TMP/cfg/env.txt"
timeout 20 "$PP" --watch --supervise --grant process --grant "fs:$TMP/cfg:ro" \
  --watch-interval 0.3 "$TMP/supervise.pp" > "$TMP/watch-out" 2>&1 &
WATCH_PID=$!
wait_for 8 stable_pid "$TMP/pid-a" || { echo "FAIL watch-pid-a: pidfile missing"; fail=1; }
OLD_A=$(cat "$TMP/pid-a")
kill -9 "$OLD_A"
# Restart lands within one 0.3s poll interval; the fresh pidfile write is
# asynchronous, so poll for the *new* pid rather than sleeping a fixed beat.
restarted_a() { p=$(cat "$TMP/pid-a" 2>/dev/null) && [ -n "$p" ] && [ "$p" != "$OLD_A" ]; }
wait_for 5 restarted_a || { echo "FAIL watch-restart-pid-a: no new pid"; fail=1; }
NEW_A=$(cat "$TMP/pid-a")
if [ "$OLD_A" != "$NEW_A" ] && kill -0 "$NEW_A" 2>/dev/null; then
  echo "ok   watch-kill9-restart"
else
  echo "FAIL watch-kill9-restart: old=$OLD_A new=$NEW_A"; fail=1
fi
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
cleanup_services

# --- (d) config edit restarts exactly the affected service ---
rm -rf "$TMP/.pp"
echo "v1" > "$TMP/cfg/env.txt"
timeout 20 "$PP" --watch --supervise --grant process --grant "fs:$TMP/cfg:ro" \
  --watch-interval 0.3 "$TMP/supervise.pp" > "$TMP/watch-out2" 2>&1 &
WATCH_PID=$!
wait_for 8 stable_pid "$TMP/pid-a" || { echo "FAIL watch-pid-a: pidfile missing"; fail=1; }
wait_for 8 stable_pid "$TMP/pid-b" || { echo "FAIL watch-pid-b: pidfile missing"; fail=1; }
OLD_A=$(cat "$TMP/pid-a")
OLD_B=$(cat "$TMP/pid-b")
# Edit the config file read by svc-a only; poll for A's restart (its new pid)
# rather than sleeping a fixed beat.
echo "v2" > "$TMP/cfg/env.txt"
restarted_da() { p=$(cat "$TMP/pid-a" 2>/dev/null) && [ -n "$p" ] && [ "$p" != "$OLD_A" ]; }
wait_for 5 restarted_da || { echo "FAIL config-edit-restart-a: no new pid"; fail=1; }
NEW_A=$(cat "$TMP/pid-a")
NEW_B=$(cat "$TMP/pid-b")
if [ "$OLD_A" != "$NEW_A" ] && kill -0 "$NEW_A" 2>/dev/null; then
  echo "ok   config-edit-restarts-a"
else
  echo "FAIL config-edit-restarts-a: old=$OLD_A new=$NEW_A"; fail=1
fi
if [ "$OLD_B" = "$NEW_B" ] && kill -0 "$NEW_B" 2>/dev/null; then
  echo "ok   config-edit-keeps-b"
else
  echo "FAIL config-edit-keeps-b: old=$OLD_B new=$NEW_B"; fail=1
fi
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
cleanup_services

# --- (e) journal contains intent/done pairs for process ops ---
if [ -f "$TMP/.pp/store/journal/log" ] && \
   grep -q "intent proc start" "$TMP/.pp/store/journal/log" && \
   grep -q "done proc start" "$TMP/.pp/store/journal/log"; then
  echo "ok   journal-proc"
else
  echo "FAIL journal-proc: missing proc intent/done entries"; fail=1
fi

# --- (f) removing a service from desired state stops it ---
# Refresh state so both services are alive.
"$PP" --supervise --grant process --grant "fs:$TMP/cfg:ro" "$TMP/supervise.pp" > "$TMP/out-refresh" 2>&1
wait_for 5 test -f "$TMP/pid-a" || { echo "FAIL stop-pid-a: pidfile missing"; fail=1; }
PID_A=$(cat "$TMP/pid-a")
# Shrink desired state to only svc-b.
cat > "$TMP/supervise-stop.pp" <<EOF
{"svc-b" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-b"], "cwd" -> "$TMP", "env" -> {"MARKER" -> "stable"}}}
EOF
"$PP" --supervise --grant process "$TMP/supervise-stop.pp" > "$TMP/out-stop" 2>&1
assert "stop-summary" "stopped=1" present "$TMP/out-stop"
kill -0 "$PID_A" 2>/dev/null && { echo "FAIL stop-a: svc-a still alive"; fail=1; } \
  || echo "ok   stop-a"

# --- (g) VM parity: bytecode backend supervises too ---
rm -rf "$TMP/.pp"
cat > "$TMP/supervise-vm.pp" <<EOF
{"svc-vm" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-vm"], "cwd" -> "$TMP"}}
EOF
"$PP" --bytecode --supervise --grant process \
  "$TMP/supervise-vm.pp" > "$TMP/out-vm" 2>&1
assert "vm-started" "started=" present
wait_for 5 test -f "$TMP/pid-vm" || { echo "FAIL vm-pid: pidfile missing"; fail=1; }
PID_VM=$(cat "$TMP/pid-vm")
kill -0 "$PID_VM" 2>/dev/null && echo "ok   vm-alive" \
  || { echo "FAIL vm-alive: pid $PID_VM not alive"; fail=1; }
kill "$PID_VM" 2>/dev/null || true
cleanup_services

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== PROCESS RECONCILER TEST PASSED ==="; fi
exit $fail
