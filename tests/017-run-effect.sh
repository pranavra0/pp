#!/usr/bin/env bash
# The scripting-tier `run` process effect.
#
#   (perform run CMD ARG...) executes a process and returns
#   {"exit" int, "out" string, "err" string}. Authority enters only via
#   `--grant process` (SPEC law 22): no grant, no exec.
#
#   Ambient processes cannot produce complete validating traces, so `run`
#   is rejected inside cached nodes even when process authority is present.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SRC="$TMP/src"
mkdir -p "$SRC"

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

run() { (cd "$TMP" && "$PP" "$@" > "$TMP/out" 2>&1); }

# --- (a) no process grant ⇒ capability error, nothing executes ---
cat > "$TMP/a.pp" <<'EOF'
perform run("echo", "hi")
EOF
run "$TMP/a.pp"
assert "nocap-denied"      "apability" present
assert "nocap-no-exec"     "^hi$"      absent

# --- (b) granted: run executes, result map carries out and exit ---
cat > "$TMP/b.pp" <<'EOF'
perform log(hash-map-get(perform run("echo", "hi"), "out"))
print(hash-map-get(perform run("sh", "-c", "exit 3"), "exit"))
EOF
run --grant process "$TMP/b.pp"
assert "run-out"           "hi"        present
assert "run-exit-code"     "3"         present

# --- (c) ambient execution is rejected inside a node ---
cat > "$TMP/c.pp" <<EOF
force(node { perform run("sh", "-c", "cat $SRC/in.txt") })
EOF
run --grant process --grant "fs:$SRC:ro" "$TMP/c.pp"
assert "node-run-denied" "scripting-tier only" present

# --- (d) absolute write-file inside a node errors (even with rw grant, per
#         SPEC law 18); scripting-tier write-file is unchanged ---
cat > "$TMP/e1.pp" <<EOF
force(node { perform write-file("$TMP/evil.txt", "X") })
EOF
cat > "$TMP/e2.pp" <<EOF
perform write-file("$TMP/ok.txt", "X")
EOF
run --grant process --grant "fs:$TMP:rw" "$TMP/e1.pp"
assert "node-write-denied"  "sandbox" present
if [ -f "$TMP/evil.txt" ]; then echo "FAIL node-write-leak: evil.txt written"; fail=1
else echo "ok   node-write-no-leak"; fi
run --grant "fs:$TMP:rw" "$TMP/e2.pp"
if [ -f "$TMP/ok.txt" ]; then echo "ok   scripting-write-works"
else echo "FAIL scripting-write-works: ok.txt missing"; cat "$TMP/out"; fail=1; fi
rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== RUN EFFECT (D13) TEST PASSED ==="; fi
exit $fail
