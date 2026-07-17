#!/usr/bin/env bash
# pins: LAW-24
# The runtime/traced split: loader authority is bounded, and loader reads are
# runtime-tagged trace cells.
#
#   `load`/`load-module`/`island` run with the INTERPRETER's authority, not
#   the user capability set. That authority is bounded: the directories of
#   the CLI-named programs, the working directory, and ~/.pp. Loading from
#   anywhere else is an error — closing the hole where the loader was an
#   unbounded ambient bypass.
#
#   Each loader read is recorded as a `runtime:file:<path>` trace cell:
#   it participates in cache VALIDITY (editing a loaded file invalidates
#   nodes that loaded it) but NOT in the caller's hit-time authority
#   requirement — a hit on a node that loaded a module needs no fs grant
#   over the module (the read was the loader's, not the user's).
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

TMP=$(mktemp -d)
export HOME="$TMP"
APP="$TMP/app"; ELSEWHERE="$TMP/elsewhere"; RUNDIR="$TMP/rundir"
mkdir -p "$APP" "$ELSEWHERE" "$RUNDIR"
fail=0

assert() {  # NAME PATTERN present|absent
  local name="$1" pat="$2" mode="$3"
  if grep -qE "$pat" "$TMP/out"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$TMP/out"; fail=1; fi
}

# pp runs from RUNDIR so cwd is a source root distinct from APP and ELSEWHERE.
run() { (cd "$RUNDIR" && "$PP" "$@" > "$TMP/out" 2>&1); }

# --- (a) loading beside the program works with ZERO grants (loader
#         authority, not user caps) ---
printf 'let libval = "LIBVAL"\n' > "$APP/lib.pp"
cat > "$APP/main.pp" <<EOF
load("$APP/lib.pp")
perform log(libval)
EOF
run "$APP/main.pp"
assert "beside-program-loads" "LIBVAL" present

# --- (b) loading OUTSIDE every source root is refused, grants or no ---
printf 'let evil = "EVIL"\n' > "$ELSEWHERE/evil.pp"
cat > "$APP/esc.pp" <<EOF
load("$ELSEWHERE/evil.pp")
perform log(evil)
EOF
run "$APP/esc.pp"
assert "outside-refused"        "source root" present
assert "outside-not-evaluated"  "EVIL"        absent
run --grant "fs:$TMP:rw" "$APP/esc.pp"
assert "outside-refused-despite-grant" "source root" present

# --- (c) a node that loads a module: the load is a runtime cell —
#         validity yes, authority requirement no ---
printf 'let libval = "V1"\n' > "$APP/lib.pp"
cat > "$APP/node.pp" <<EOF
perform log(force(node {
  perform log("COMPUTE")
  do {
    load("$APP/lib.pp")
    libval
  }
}))
EOF
rm -rf "$TMP/.pp"
run "$APP/node.pp"                # zero grants throughout
assert "node-run1-miss"   "COMPUTE" present
assert "node-run1-V1"     "V1"      present
run "$APP/node.pp"
assert "node-run2-hit"    "COMPUTE" absent   # hit needs NO fs grant over lib.pp
assert "node-run2-V1"     "V1"      present
printf 'let libval = "V2"\n' > "$APP/lib.pp"
run "$APP/node.pp"
assert "node-run3-stale"  "COMPUTE" present  # editing the module invalidates
assert "node-run3-V2"     "V2"      present

# --- (e) stdlib loads relative to cwd still work (cwd is a source root) ---
mkdir -p "$RUNDIR/stdlib"
printf 'let stdval = "STDLIB-OK"\n' > "$RUNDIR/stdlib/x.pp"
cat > "$APP/std.pp" <<'EOF'
load("stdlib/x.pp")
perform log(stdval)
EOF
run "$APP/std.pp"
assert "cwd-relative-load" "STDLIB-OK" present

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== LOADER AUTHORITY (Q6/D8c) TEST PASSED ==="; fi
exit $fail
