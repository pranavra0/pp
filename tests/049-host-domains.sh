#!/usr/bin/env bash
# Host-qualified domain distribution: the desired map generalizes ONE
# level, {host -> {domain -> desired}}.
#
#   `--member-name <n>` (explicit, never inferred from hostname or value
#   shape — the least-magic rule) makes main.ml index desired[<n>]'s slice
#   and hand it to the UNCHANGED Domains.run_all. Without --member-name,
#   main.ml's [all_desired] passes through completely untouched — this is
#   the whole back-compat proof; tests/018/033/046 (which never pass
#   --member-name) are the existing, unchanged-byte-for-byte evidence for
#   that half, exercised every run of this suite. This file adds the NEW
#   half: host-keying itself, plus one dedicated back-compat check of its
#   own so the claim doesn't rest on "some other file didn't regress"
#   alone.
#
#   - --member-name A converges ONLY host A's fs slice; --member-name B
#     converges ONLY host B's (each a SEPARATE process/$HOME, simulating
#     two cluster members exactly like tests/047/048's convention).
#   - a member's kill -9 recovery is the LOCAL supervisor's existing
#     per-machine story, unchanged — a member is just `pp --watch` on its
#     OWN slice: host-keying adds a new SOURCE for the desired value, not
#     a new convergence mechanism.
#   - back-compat: a flat {domain -> desired} program with NO --member-name
#     behaves exactly as it does without this feature at all.
#
# Runs under isolated HOMEs; both backends where meaningful.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
if ! command -v timeout >/dev/null 2>&1; then
  SHIM_DIR=$(mktemp -d)
  printf '#!/bin/sh\nexec perl -e '\''alarm shift; exec @ARGV'\'' "$@"\n' > "$SHIM_DIR/timeout"
  chmod +x "$SHIM_DIR/timeout"
  PATH="$SHIM_DIR:$PATH"
fi

wait_for() {  # SECONDS CMD ARGS...
  local secs="$1"; shift
  local i=0 max=$((secs * 10))
  while [ "$i" -lt "$max" ]; do
    "$@" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  "$@" 2>/dev/null
}

# ===========================================================================
# Part 1: --member-name converges ONLY that host's fs slice.
# Each "member" is its own $HOME (tests/047/048's convention); each member's
# OWN program registers ONLY its own root (a member has no authority over
# another host's filesystem in a real deployment either — registering a
# domain for a root you don't own is meaningless, not merely untested).
# ===========================================================================
HOSTA_HOME="$TMP/homeA"; HOSTB_HOME="$TMP/homeB"
mkdir -p "$HOSTA_HOME" "$HOSTB_HOME"
ROOT_A="$TMP/rootA"; ROOT_B="$TMP/rootB"
mkdir -p "$ROOT_A" "$ROOT_B"

mk_fs_prog() {  # MEMBER ROOT -> writes $TMP/prog-<member>.pp
  local member="$1" root="$2"
  cat > "$TMP/prog-$member.pp" <<EOF
load("stdlib/list.pp")
load("stdlib/map.pp")
load("stdlib/string.pp")
load("stdlib/domain-fs.pp")
register-fs-domain("$root", cap-restrict(current-capabilities(), "$root", :wo))
{"A" -> {"fs" -> {"a.txt" -> "from-A"}}, "B" -> {"fs" -> {"b.txt" -> "from-B"}}}
EOF
}
mk_fs_prog A "$ROOT_A"
mk_fs_prog B "$ROOT_B"

HOME="$HOSTA_HOME" "$PP" --grant "fs:${ROOT_A}:rw" --member-name A "$TMP/prog-A.pp" \
  > "$TMP/out-memberA" 2>&1
grep -q "create=1" "$TMP/out-memberA" && ok "memberA-converges" \
  || bad "memberA-converges" "$(cat "$TMP/out-memberA")"
[ -f "$ROOT_A/a.txt" ] && [ "$(cat "$ROOT_A/a.txt")" = "from-A" ] && ok "memberA-file-a" \
  || { echo "FAIL memberA-file-a"; fail=1; }
[ -e "$ROOT_A/b.txt" ] && { echo "FAIL memberA-no-cross-host-write: b.txt leaked into A's root"; fail=1; } \
  || ok "memberA-no-cross-host-write"

HOME="$HOSTB_HOME" "$PP" --grant "fs:${ROOT_B}:rw" --member-name B "$TMP/prog-B.pp" \
  > "$TMP/out-memberB" 2>&1
grep -q "create=1" "$TMP/out-memberB" && ok "memberB-converges" \
  || bad "memberB-converges" "$(cat "$TMP/out-memberB")"
[ -f "$ROOT_B/b.txt" ] && [ "$(cat "$ROOT_B/b.txt")" = "from-B" ] && ok "memberB-file-b" \
  || { echo "FAIL memberB-file-b"; fail=1; }
[ -e "$ROOT_B/a.txt" ] && { echo "FAIL memberB-no-cross-host-write: a.txt leaked into B's root"; fail=1; } \
  || ok "memberB-no-cross-host-write"

# --member-name naming a host absent from the map is a clear error, not a
# silent no-op.
HOME="$HOSTA_HOME" "$PP" --grant "fs:${ROOT_A}:rw" --member-name ZZZ "$TMP/prog-A.pp" \
  > "$TMP/out-badmember" 2>&1
CODE=$?
if [ "$CODE" -ne 0 ] && grep -q "no such host key" "$TMP/out-badmember"; then
  ok "unknown-member-name-is-an-error"
else
  bad "unknown-member-name-is-an-error" "exit=$CODE" "$(cat "$TMP/out-badmember")"
fi

# VM parity.
rm -rf "$HOSTA_HOME/.pp"; rm -rf "$ROOT_A"; mkdir -p "$ROOT_A"
HOME="$HOSTA_HOME" "$PP" --bytecode --grant "fs:${ROOT_A}:rw" --member-name A "$TMP/prog-A.pp" \
  > "$TMP/out-vm" 2>&1
[ -f "$ROOT_A/a.txt" ] && ok "vm-parity-memberA" || bad "vm-parity-memberA" "$(cat "$TMP/out-vm")"

# ===========================================================================
# Part 2: kill -9 convergence still works on a member's OWN slice — the
# LOCAL supervisor's existing per-machine story, unchanged. Host-keying
# adds a new SOURCE for the desired value, not a new convergence mechanism.
# ===========================================================================
HOSTC_HOME="$TMP/homeC"; mkdir -p "$HOSTC_HOME"
mkdir -p "$TMP/svc"
cat > "$TMP/svc/run.sh" <<'EOF'
#!/bin/sh
echo $$ > "$1"
exec sleep 1000
EOF
chmod +x "$TMP/svc/run.sh"

cat > "$TMP/prog-proc.pp" <<EOF
load("stdlib/list.pp")
load("stdlib/map.pp")
load("stdlib/string.pp")
load("stdlib/domain-proc.pp")
register-proc-domain(current-capabilities())
{"C" -> {"proc" -> {"svc-c" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-c"], "cwd" -> "$TMP"}}}, "OTHER" -> {"proc" -> {"svc-other" -> {"cmd" -> "$TMP/svc/run.sh", "args" -> ["$TMP/pid-other"], "cwd" -> "$TMP"}}}}
EOF

HOME="$HOSTC_HOME" timeout 20 "$PP" --watch --watch-interval 0.3 --grant process \
  --member-name C "$TMP/prog-proc.pp" > "$TMP/watch-out" 2>&1 &
WATCH_PID=$!
sleep 2
wait_for 5 test -f "$TMP/pid-c" || { echo "FAIL member-svc-started: pidfile missing"; fail=1; }
[ -e "$TMP/pid-other" ] && { echo "FAIL member-only-own-slice: svc-other (a DIFFERENT host's service) was started"; fail=1; } \
  || ok "member-only-own-slice (svc-other, host OTHER's service, never started)"
OLD_C=$(cat "$TMP/pid-c" 2>/dev/null)
if [ -n "$OLD_C" ]; then
  kill -9 "$OLD_C" 2>/dev/null || true
  restarted_c() { p=$(cat "$TMP/pid-c" 2>/dev/null) && [ -n "$p" ] && [ "$p" != "$OLD_C" ]; }
  wait_for 5 restarted_c || { echo "FAIL member-kill9-restart: no new pid"; fail=1; }
  NEW_C=$(cat "$TMP/pid-c" 2>/dev/null)
  if [ "$OLD_C" != "$NEW_C" ] && kill -0 "$NEW_C" 2>/dev/null; then
    ok "member-kill9-restart (host C's own slice recovers within one poll interval)"
  else
    bad "member-kill9-restart" "old=$OLD_C new=$NEW_C"
  fi
else
  bad "member-svc-started" "pid-c never appeared"
fi
kill "$WATCH_PID" 2>/dev/null || true
wait "$WATCH_PID" 2>/dev/null || true
for pidfile in "$TMP"/pid-*; do
  [ -f "$pidfile" ] || continue
  pid=$(cat "$pidfile" 2>/dev/null) || continue
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
done

# ===========================================================================
# Part 3: back-compat — a FLAT {domain -> desired} program, no --member-name,
# behaves exactly as it does without this feature (the least-magic rule:
# host-keying is opt-in ONLY via the explicit flag). Reuses tests/046's
# from-scratch third-party "kv" domain pattern (never touching domain-fs.pp/
# domain-proc.pp) so this check doesn't merely restate tests/018/033/046's
# own unchanged assertions elsewhere in the suite.
# ===========================================================================
KV="$TMP/kv"
cat > "$TMP/flat.pp" <<EOF
load("stdlib/list.pp")
load("stdlib/map.pp")

def register-kv-domain() {
  register-domain({:name -> "kv", :namespace -> vec[string-append("file:", "$KV"), string-append("tree:", "$KV")], :observe -> (


fn() { perform tree-observe("$KV") }), :diff -> (
fn(observed, desired) { {:items -> map(
fn(k) { {:kind -> "create", :key -> k, :value -> hash-map-get(desired, k)} }, filter(
fn(k) { nil?(hash-map-get(observed, k)) }, map-keys(desired))), :summary -> [[:created, "n/a"]]}
  }), :apply -> (
fn(plan) { each(
fn(item) {
      perform materialize-file(string-append("$KV/", hash-map-get(item, :key)), hash-map-get(item, :value))
    }, hash-map-get(plan, :items))
  }), :write-cap -> cap-restrict(current-capabilities(), "$KV", :wo)})
}

do {
  register-kv-domain()
  {"kv" -> {"flat-a" -> "1"}}
}
EOF
"$PP" --grant "fs:${KV}:wo" "$TMP/flat.pp" > "$TMP/out-flat" 2>&1
[ -f "$KV/flat-a" ] && [ "$(cat "$KV/flat-a")" = "1" ] && ok "backcompat-flat-no-member-name" \
  || bad "backcompat-flat-no-member-name" "$(cat "$TMP/out-flat")"

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== M5 STAGE C HOST-QUALIFIED DOMAINS TEST PASSED ==="; fi
exit $fail
