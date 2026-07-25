#!/usr/bin/env bash
# The `run` process effect and its per-node sandbox.
#
#   (perform run CMD ARG...) executes a process and returns
#   {"exit" int, "out" string, "err" string}. Authority enters only via
#   `--grant process` (SPEC law 22): no grant, no exec.
#
#   Conservative invalidation: inside a node, a run records
#     - `tool:<resolved-binary>` — the command's content hash, and
#     - `tree:<root>`           — a whole-tree content hash for EVERY
#                                 fs-read-granted root,
#   so a cached run-node re-runs when the tool or anything under a granted
#   tree changes — even files pp itself never read. Ambient reads outside
#   those trees remain an honest edge; depfile adapters refine trusted tools.
#
#   Sandbox (SPEC law 18): inside a node, `run` executes in a per-node scratch
#   directory; relative slurp/write-file resolve there (unrecorded,
#   capability-free — scratch is node-local memory); absolute write-file
#   inside a node is an error. Scripting-tier write-file is unchanged.
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

# --- (c) a run inside a node records tool + granted-tree cells ---
printf 'DATA1\n' > "$SRC/in.txt"
cat > "$TMP/c.pp" <<EOF
perform log(force(node {
  perform log("RUN")
  hash-map-get(perform run("sh", "-c", "cat $SRC/in.txt"), "out")
}))
EOF
rm -rf "$TMP/.pp"
run --grant process --grant "fs:$SRC:ro" "$TMP/c.pp"
assert "node-run1-miss"    "RUN"    present
assert "node-run1-DATA1"   "DATA1"  present
run --grant process --grant "fs:$SRC:ro" "$TMP/c.pp"
assert "node-run2-hit"     "RUN"    absent
assert "node-run2-DATA1"   "DATA1"  present
printf 'DATA2\n' > "$SRC/in.txt"
run --grant process --grant "fs:$SRC:ro" "$TMP/c.pp"
assert "node-run3-stale"   "RUN"    present   # tree cell caught a read pp never saw
assert "node-run3-DATA2"   "DATA2"  present
# coarse floor: an unrelated file under the granted root also invalidates
printf 'x\n' > "$SRC/other.txt"
run --grant process --grant "fs:$SRC:ro" "$TMP/c.pp"
assert "node-run4-coarse"  "RUN"    present

# --- (d) per-node sandbox: run writes scratch, relative slurp reads it,
#         nothing lands in the caller's cwd, and the node caches ---
cat > "$TMP/d.pp" <<'EOF'
perform log(force(node {
  perform log("RUN")
  do {
    perform run("sh", "-c", "printf OBJ > a.o")
    slurp("a.o")
  }
}))
EOF
rm -rf "$TMP/.pp"
rm -f "$TMP/a.o"
run --grant process "$TMP/d.pp"
assert "sandbox-run1-miss" "RUN"    present
assert "sandbox-run1-OBJ"  "OBJ"    present
if [ -f "$TMP/a.o" ]; then echo "FAIL sandbox-leak: a.o escaped into cwd"; fail=1
else echo "ok   sandbox-no-leak"; fi
run --grant process "$TMP/d.pp"
assert "sandbox-run2-hit"  "RUN"    absent
assert "sandbox-run2-OBJ"  "OBJ"    present

# --- (e) absolute write-file inside a node errors (even with rw grant, per
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
