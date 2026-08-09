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

# --- (d) absolute write-file inside a node errors even with an rw grant
#         (SPEC law 18); scripting-tier write-file requires explicit authority ---
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
# --- (e) scripting write-file requires a write grant; read-only is denied ---
cat > "$TMP/e3.pp" <<EOF
perform write-file("$TMP/no-grant.txt", "X")
EOF
run "$TMP/e3.pp"
assert "scripting-write-no-grant-denied" "capability error" present
if [ -f "$TMP/no-grant.txt" ]; then echo "FAIL scripting-write-no-grant-leak"; fail=1
else echo "ok   scripting-write-no-grant-no-leak"; fi
cat > "$TMP/e4.pp" <<EOF
perform write-file("$TMP/read-only.txt", "X")
EOF
run --grant "fs:$TMP:ro" "$TMP/e4.pp"
assert "scripting-write-read-only-denied" "capability error" present
if [ -f "$TMP/read-only.txt" ]; then echo "FAIL scripting-write-read-only-leak"; fail=1
else echo "ok   scripting-write-read-only-no-leak"; fi
# --- (f) process observation/mutation requires process authority too ---
cat > "$TMP/reap.pp" <<'EOF'
perform proc-reap()
EOF
run "$TMP/reap.pp"
assert "proc-reap-no-grant-denied" "capability error" present
run --grant process "$TMP/reap.pp"
assert "proc-reap-granted" "capability error" absent

# --- (g) a dangling symlink cannot redirect an allowed write outside its grant ---
mkdir -p "$TMP/allowed"
ln -s "$TMP/escape.txt" "$TMP/allowed/link"
cat > "$TMP/e5.pp" <<EOF
perform write-file("$TMP/allowed/link", "X")
EOF
run --grant "fs:$TMP/allowed:rw" "$TMP/e5.pp"
assert "scripting-write-symlink-denied" "refusing symlink" present
if [ -f "$TMP/escape.txt" ]; then echo "FAIL scripting-write-symlink-leak"; fail=1
else echo "ok   scripting-write-symlink-no-leak"; fi
 
 # --- (h) CR/LF-containing argv is rejected before child execution ---
 rm -f "$TMP/crlf-sentinel"
 printf 'perform run("sh", "-c", "touch %s\\r\\n")\n' "$TMP/crlf-sentinel" > "$TMP/crlf.pp"
 run --grant process "$TMP/crlf.pp"
 assert "run-crlf-invalid" "invalid|journal" present
 if [ -e "$TMP/crlf-sentinel" ]; then echo "FAIL run-crlf-child-executed"; fail=1
 else echo "ok   run-crlf-child-blocked"; fi
 
 # --- (i) a journal log leaf that is not a regular file blocks execution ---
 rm -f "$TMP/journal-sentinel"
 rm -rf "$TMP/.pp"
 mkdir -p "$TMP/.pp/store/journal"
 mkdir "$TMP/.pp/store/journal/log"
 cat > "$TMP/journal-leaf.pp" <<EOF
perform run("sh", "-c", "touch $TMP/journal-sentinel")
EOF
 run --grant process "$TMP/journal-leaf.pp"
 assert "journal-invalid-leaf" "invalid|journal" present
 if [ -e "$TMP/journal-sentinel" ]; then echo "FAIL journal-leaf-child-executed"; fail=1
 else echo "ok   journal-leaf-child-blocked"; fi
 rm -rf "$TMP/.pp"
if [ "$fail" -eq 0 ]; then echo "=== RUN EFFECT (D13) TEST PASSED ==="; fi
exit $fail
