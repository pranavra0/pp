#!/bin/sh
# A desired process map replaces a restart loop. The supervisor starts a
# service, notices SIGKILL, and converges it back within one poll interval.
export HOME=$(mktemp -d)
trap 'kill "$WATCH_PID" 2>/dev/null || true; kill "$(cat "$HOME/pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$HOME"' EXIT
CFG="$HOME/config"
PID="$HOME/pid"
mkdir -p "$HOME"
printf 'release-v1' > "$CFG"

cat > "$HOME/service.sh" <<'SH'
#!/bin/sh
echo "$$" > "$1"
while :; do sleep 0.1; done
SH
chmod +x "$HOME/service.sh"

cat > "$HOME/supervise.pp" <<EOF
let release = slurp("$CFG")
{"web" -> {
  "cmd" -> "$HOME/service.sh",
  "args" -> ["$PID"],
  "cwd" -> "$HOME",
  "env" -> {"RELEASE" -> release}
}}
EOF

timeout 12 "$PP" --watch --supervise --watch-interval 0.2 \
  --grant process --grant "fs:$HOME:ro" "$HOME/supervise.pp" \
  > "$HOME/watch.out" 2>&1 &
WATCH_PID=$!

wait_for_pid() {
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$PID" ]; do sleep 0.1; i=$((i + 1)); done
}
wait_for_pid
OLD_PID=$(cat "$PID")
echo '$ pp --watch --supervise ...              # desired service starts'
echo 'web started: yes'

kill -9 "$OLD_PID"
i=0
while [ "$i" -lt 50 ]; do
  [ -s "$PID" ] && NEW_PID=$(cat "$PID") && [ "$NEW_PID" != "$OLD_PID" ] && break
  sleep 0.1
  i=$((i + 1))
done

echo
echo '# Kill the process outside pp.'
echo 'kill -9 WEB_PID'
if [ "${NEW_PID:-}" != "$OLD_PID" ] && kill -0 "$NEW_PID" 2>/dev/null; then
  echo 'web restarted: yes'
else
  echo 'web restarted: no'
  exit 1
fi
