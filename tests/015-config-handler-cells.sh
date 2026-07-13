#!/usr/bin/env bash
# LAW 33 / LAW 26: config and the handler stack are OBSERVATIONS, not identity.
#
# The node key must cover code + free-var value hashes ONLY (LAW 20). Config
# and handlers used to be folded into the key conservatively, so changing an
# ambient config value or swapping any handler re-keyed every node under it —
# even nodes that never read config or performed the effect. The trace-cell
# treatment fixes this:
#   - (config k) inside a node records a `config:<k>` cell whose observed hash
#     is the resolved value (or an absent marker); a hit re-observes it against
#     the caller's current config stack (LAW 33).
#   - every `perform` inside a node records a `handler:<effect>` cell whose
#     observed hash is the intercepting handler's value hash (or a builtin
#     marker); a hit re-observes it against the caller's handler stack, so a
#     mock read-file and the real one never cross-contaminate (LAW 26).
#
# Runs under an isolated HOME. COMPUTE in output = the node body ran (miss);
# per LAW 17 a hit does not replay it.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# --- (a) ambient config a node never reads must NOT re-key it (LAW 33) ---
rm -rf "$TMP/.pp"
cat > "$TMP/a1.pp" <<'EOF'
with-config({"amb" -> "A"}) {
  perform log(force(node {
    perform log("COMPUTE")
    42
  }))
}
EOF
cat > "$TMP/a2.pp" <<'EOF'
with-config({"amb" -> "B"}) {
  perform log(force(node {
    perform log("COMPUTE")
    42
  }))
}
EOF
run "$TMP/a1.pp"; assert "cfg-unrelated-run1-miss" "COMPUTE" present
run "$TMP/a2.pp"; assert "cfg-unrelated-still-hit" "COMPUTE" absent

# --- (b) a config value a node DOES read is an observation: change ⇒
#         recompute, revert ⇒ hit ---
rm -rf "$TMP/.pp"
cat > "$TMP/b1.pp" <<'EOF'
with-config({"k" -> "V1"}) {
  perform log(force(node {
    perform log("COMPUTE")
    config("k")
  }))
}
EOF
cat > "$TMP/b2.pp" <<'EOF'
with-config({"k" -> "V2"}) {
  perform log(force(node {
    perform log("COMPUTE")
    config("k")
  }))
}
EOF
run "$TMP/b1.pp"; assert "cfg-read-run1-miss"   "COMPUTE" present
                  assert "cfg-read-run1-V1"     "V1"      present
run "$TMP/b2.pp"; assert "cfg-read-run2-miss"   "COMPUTE" present
                  assert "cfg-read-run2-V2"     "V2"      present
run "$TMP/b1.pp"; assert "cfg-read-revert-hit"  "COMPUTE" absent
                  assert "cfg-read-revert-V1"   "V1"      present

# --- (c) an ABSENT config key is a real observation: default served, then
#         providing the key recomputes, then absence hits again ---
rm -rf "$TMP/.pp"
cat > "$TMP/c1.pp" <<'EOF'
perform log(force(node {
  perform log("COMPUTE")
  config("k", "DEF")
}))
EOF
cat > "$TMP/c2.pp" <<'EOF'
with-config({"k" -> "V5"}) {
  perform log(force(node {
    perform log("COMPUTE")
    config("k", "DEF")
  }))
}
EOF
run "$TMP/c1.pp"; assert "cfg-absent-run1-miss"  "COMPUTE" present
                  assert "cfg-absent-run1-DEF"   "DEF"     present
run "$TMP/c2.pp"; assert "cfg-absent-run2-miss"  "COMPUTE" present
                  assert "cfg-absent-run2-V5"    "V5"      present
run "$TMP/c1.pp"; assert "cfg-absent-revert-hit" "COMPUTE" absent
                  assert "cfg-absent-revert-DEF" "DEF"     present

# --- (d) a handler for an effect the node never performs must NOT re-key it
#         (LAW 26: handlers are not identity) ---
rm -rf "$TMP/.pp"
cat > "$TMP/d1.pp" <<'EOF'
with-handler(ask = fn(n) { "H1" }) {
  perform log(force(node {
    perform log("COMPUTE")
    42
  }))
}
EOF
cat > "$TMP/d2.pp" <<'EOF'
with-handler(ask = fn(n) { "H2" }) {
  perform log(force(node {
    perform log("COMPUTE")
    42
  }))
}
EOF
run "$TMP/d1.pp"; assert "hnd-unrelated-run1-miss" "COMPUTE" present
run "$TMP/d2.pp"; assert "hnd-unrelated-still-hit" "COMPUTE" absent

# --- (e) a semantic handler the node DID perform through is an observation:
#         swap ⇒ recompute, revert ⇒ hit ---
rm -rf "$TMP/.pp"
cat > "$TMP/e1.pp" <<'EOF'
with-handler(ask = fn(n) { "A1" }) {
  perform log(force(node {
    perform log("COMPUTE")
    perform ask(0)
  }))
}
EOF
cat > "$TMP/e2.pp" <<'EOF'
with-handler(ask = fn(n) { "A2" }) {
  perform log(force(node {
    perform log("COMPUTE")
    perform ask(0)
  }))
}
EOF
run "$TMP/e1.pp"; assert "hnd-sem-run1-miss"  "COMPUTE" present
                  assert "hnd-sem-run1-A1"    "A1"      present
run "$TMP/e2.pp"; assert "hnd-sem-run2-miss"  "COMPUTE" present
                  assert "hnd-sem-run2-A2"    "A2"      present
run "$TMP/e1.pp"; assert "hnd-sem-revert-hit" "COMPUTE" absent
                  assert "hnd-sem-revert-A1"  "A1"      present

# --- (f) mock read-file vs the builtin: two traces under one key, no
#         cross-contamination (the LAW 26 acceptance test) ---
rm -rf "$TMP/.pp"
printf 'REAL\n' > "$TMP/f.txt"
cat > "$TMP/f-real.pp" <<EOF
perform log(force(node {
  perform log("COMPUTE")
  perform read-file("$TMP/f.txt")
}))
EOF
cat > "$TMP/f-mock.pp" <<EOF
with-handler(read-file = fn(p) { "MOCKED" }) {
  perform log(force(node {
    perform log("COMPUTE")
    perform read-file("$TMP/f.txt")
  }))
}
EOF
run --grant "fs:$TMP:ro" "$TMP/f-real.pp"; assert "mock-real-run1-miss"  "COMPUTE" present
                                           assert "mock-real-run1-REAL" "REAL"    present
run --grant "fs:$TMP:ro" "$TMP/f-mock.pp"; assert "mock-mock-run2-miss" "COMPUTE" present
                                           assert "mock-mock-run2-MOCK" "MOCKED"  present
run --grant "fs:$TMP:ro" "$TMP/f-real.pp"; assert "mock-real-run3-hit"  "COMPUTE" absent
                                           assert "mock-real-run3-REAL" "REAL"    present
                                           assert "mock-real-run3-not-mocked" "MOCKED" absent
run --grant "fs:$TMP:ro" "$TMP/f-mock.pp"; assert "mock-mock-run4-hit"  "COMPUTE" absent
                                           assert "mock-mock-run4-MOCK" "MOCKED"  present

# --- (g) VM parity: the VM shares the trace-cell treatment and the store ---
rm -rf "$TMP/.pp"
run             "$TMP/b1.pp"; assert "vm-cfg-tw-populates"  "COMPUTE" present
run --bytecode  "$TMP/b1.pp"; assert "vm-cfg-hits-tw"       "COMPUTE" absent
                              assert "vm-cfg-hits-tw-V1"    "V1"      present
run --bytecode  "$TMP/b2.pp"; assert "vm-cfg-change-miss"   "COMPUTE" present
                              assert "vm-cfg-change-V2"     "V2"      present
run --bytecode  "$TMP/a1.pp"; assert "vm-amb-run1-miss"     "COMPUTE" present
run --bytecode  "$TMP/a2.pp"; assert "vm-amb-still-hit"     "COMPUTE" absent
run --bytecode  "$TMP/e1.pp"; assert "vm-hnd-run1-miss"     "COMPUTE" present
run --bytecode  "$TMP/e2.pp"; assert "vm-hnd-run2-miss"     "COMPUTE" present
run --bytecode  "$TMP/e1.pp"; assert "vm-hnd-revert-hit"    "COMPUTE" absent

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CONFIG/HANDLER TRACE-CELL TEST PASSED ==="; fi
exit $fail
