#!/usr/bin/env bash
# pins: LAW-22b LAW-25
# In-language capability attenuation: with-caps narrows the current
# capability set, and a node captures whatever capability set was in force
# when it was CREATED, not whatever is live when it is later forced.
#
# The test below proves the capture-at-creation model, not
# merely that narrowing exists:
#
#   (a) a node CREATED under a NARROWED ambient, forced OUTSIDE that ambient
#       (under the full grant), is STILL DENIED — the node's authority was
#       fixed at creation (the node's captured capabilities), not re-derived
#       from whatever is live
#       in current_capabilities at force time.
#   (b) a node CREATED under the FULL ambient, forced INSIDE a narrower
#       with-caps extent, STILL SUCCEEDS — fixed at creation, mirroring
#       lexical closure capture of every other value kind.
#
# Both directions matter: (a) alone could be explained by "narrow wins", (b)
# alone by "broad wins" — only capture-AT-CREATION explains both.
#
# (process capability PRESERVED through an fs-only restrict — CapRestrict
# narrows filesystem authority only; non-fs channels (process, network,
# secret) pass through transparently via the check_*/CapRestrict unwrap).
# Tree-walker, isolated HOME (a fresh ~/.pp/store per case, like tests/011/013).
set -uo pipefail
. "$(dirname "$0")/lib.sh"
mkdir -p "$TMP/secret" "$TMP/other"
printf 'SECRETDATA\n' > "$TMP/secret/data.txt"
printf 'OK-OTHER\n' > "$TMP/other/x.txt"

assert() {  # NAME  secret=leaked|safe  access=ok|denied
  local name="$1" smode="$2" amode="$3"
  local leaked denied
  if grep -q "SECRETDATA" "$TMP/o"; then leaked=leaked; else leaked=safe; fi
  if grep -qE "permission denied|apability" "$TMP/o"; then denied=denied; else denied=ok; fi
  if [ "$leaked" = "$smode" ] && [ "$denied" = "$amode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: secret=$leaked (want $smode), access=$denied (want $amode)"
    cat "$TMP/o"; fail=1
  fi
}

# =====================================================================
# (a) narrowed-creation denied at broad force
# =====================================================================
cat > "$TMP/direction-a.pp" <<EOF
let narrow = cap-restrict(current-capabilities(), "$TMP/other", :ro)
let n = with-caps(narrow) { node { slurp("$TMP/secret/data.txt") } }
perform log(force(n))
EOF

rm -rf "$TMP/.pp"
"$PP" --grant "fs:$TMP:ro" "$TMP/direction-a.pp" > "$TMP/o" 2>&1
assert "plain-narrowed-creation-denied-at-broad-force"  safe denied

# =====================================================================
# (b) broad-creation succeeds under narrowed force
# =====================================================================
cat > "$TMP/direction-b.pp" <<EOF
let narrow = cap-restrict(current-capabilities(), "$TMP/other", :ro)
let m = node { slurp("$TMP/secret/data.txt") }
with-caps(narrow) { perform log(force(m)) }
EOF

rm -rf "$TMP/.pp"
"$PP" --grant "fs:$TMP:ro" "$TMP/direction-b.pp" > "$TMP/o" 2>&1
assert "plain-broad-creation-succeeds-under-narrowed-force"  leaked ok

# =====================================================================
# with-caps basic narrowing: slurp (scripting tier, no node)
# =====================================================================
cat > "$TMP/wc-slurp-denied.pp" <<EOF
with-caps(cap-restrict(current-capabilities(), "$TMP/other", :ro)) {
  print(slurp("$TMP/secret/data.txt"))
}
EOF
cat > "$TMP/wc-slurp-allowed.pp" <<EOF
with-caps(cap-restrict(current-capabilities(), "$TMP/other", :ro)) {
  print(slurp("$TMP/other/x.txt"))
}
EOF

"$PP" --grant "fs:$TMP:ro" "$TMP/wc-slurp-denied.pp" > "$TMP/o" 2>&1
assert "plain-wc-slurp-narrowed-denied" safe denied
"$PP" --grant "fs:$TMP:ro" "$TMP/wc-slurp-allowed.pp" > "$TMP/o" 2>&1
if grep -q "OK-OTHER" "$TMP/o"; then echo "ok   plain-wc-slurp-narrowed-allowed"
else echo "FAIL plain-wc-slurp-narrowed-allowed: expected OK-OTHER"; cat "$TMP/o"; fail=1; fi
# fs-only restrict — CapRestrict narrows filesystem authority only;
# non-fs channels pass through transparently).
# =====================================================================
cat > "$TMP/wc-run-restricted.pp" <<EOF
with-caps(cap-restrict(current-capabilities(), "$TMP", :ro)) {
  print(hash-map-get(perform run("echo", "hi"), "out"))
}
EOF
cat > "$TMP/wc-run-unrestricted.pp" <<EOF
print(hash-map-get(perform run("echo", "hi"), "out"))
EOF

"$PP" --grant process --grant "fs:$TMP:ro" "$TMP/wc-run-restricted.pp" > "$TMP/o" 2>&1
if grep -q "hi" "$TMP/o"; then echo "ok   plain-wc-run-restricted-allowed"
else echo "FAIL plain-wc-run-restricted-allowed: expected hi"; cat "$TMP/o"; fail=1; fi
"$PP" --grant process --grant "fs:$TMP:ro" "$TMP/wc-run-unrestricted.pp" > "$TMP/o" 2>&1
if grep -q "hi" "$TMP/o"; then echo "ok   plain-wc-run-unrestricted-allowed"
else echo "FAIL plain-wc-run-unrestricted-allowed: expected hi"; cat "$TMP/o"; fail=1; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CAPS ATTENUATION TEST PASSED ==="; fi
exit $fail
