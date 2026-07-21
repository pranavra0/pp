#!/usr/bin/env bash
# Cell-id canonicalization (SPEC law 23).
#
#   A cell-id is canonicalized before hashing: absolute real-path (symlinks
#   resolved), no trailing slash. Done once, in World_path.canonical, and
#   applied at every file:/tree:/stat:/tool:/runtime:file: construction
#   site, every --grant path, and the loader bound — so two syntactically
#   different paths naming the same inode are one cell (this path-prefix
#   bug class is closed at the cell layer).
#
#   Covers (at least four cases):
#     (a) a symlinked source tree: loader authority resolves cross-spelled
#         load targets, and a node's grant/observation pair still HITS when
#         the grant is spelled via the symlink one run and the real path the
#         next (zero recompute — the "build once through the symlink, run
#         again through the real path" story), both directions;
#     (b) macOS /var vs /private/var: same mechanism, exercised on whatever
#         symlink layer mktemp -d's own path already has (skips cleanly if
#         the host gives a symlink-free tmp path, e.g. Linux CI);
#     (c) a trailing-slash grant == the same grant without one;
#     (d) a write-target's cell-id (via `pp graph`) is byte-identical before
#         and after the file exists — canonicalizing the nonexistent path's
#         longest existing prefix and appending the rest lexically.
#
#   NFC Unicode normalization is NOT covered here — a documented residual
#   (SPEC law 23); this suite is realpath-only.
#
# Runs under an isolated HOME; single engine.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
SRC="$TMP/src"
LINK="$TMP/link"
mkdir -p "$SRC"
ln -s "$SRC" "$LINK"

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  if grep -qE "$pat" "$file"; then hit=present; else hit=absent; fi
  if [ "$hit" = "$mode" ]; then echo "ok   $name"
  else echo "FAIL $name: expected '$pat' $mode, got $hit"
       echo "--- output ---"; cat "$file"; fail=1; fi
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# --- (a1) loader authority: a source tree reached via a symlink can `load`
#          a sibling named via the REAL path, and vice versa (this closes
#          "symlinked trees are undefined behavior") ---
printf 'let libval = "LIBVAL"\n' > "$SRC/lib.pp"
cat > "$SRC/via-link.pp" <<EOF
load("$LINK/lib.pp")
perform log(libval)
EOF
run "$SRC/via-link.pp"          # invoked via the REAL path; loads via the SYMLINK
assert "loader-real-invoke-symlink-load" "LIBVAL" present

cat > "$SRC/via-real.pp" <<EOF
load("$SRC/lib.pp")
perform log(libval)
EOF
run "$LINK/via-real.pp"         # invoked via the SYMLINK path; loads via the REAL
assert "loader-symlink-invoke-real-load" "LIBVAL" present

# --- (a2) a node's tree:/tool: cells hit when the SAME content is granted
#          via a different spelling than the run that produced the trace ---
printf 'DATA1\n' > "$SRC/in.txt"
cat > "$TMP/build.pp" <<EOF
perform log(force(node {
  perform log("RUN")
  hash-map-get(perform run("sh", "-c", "cat $SRC/in.txt"), "out")
}))
EOF

rm -rf "$TMP/.pp"
run --grant process --grant "fs:$LINK:ro" "$TMP/build.pp"
assert "a2-cold-symlink-miss" "RUN"   present
assert "a2-cold-symlink-data" "DATA1" present
run --grant process --grant "fs:$SRC:ro" "$TMP/build.pp"
assert "a2-real-grant-hit"    "RUN"   absent   # <- the canonicalization proof
assert "a2-real-grant-data"   "DATA1" present

rm -rf "$TMP/.pp"
run --grant process --grant "fs:$SRC:ro" "$TMP/build.pp"
assert "a2-cold-real-miss"    "RUN"   present
run --grant process --grant "fs:$LINK:ro" "$TMP/build.pp"
assert "a2-symlink-grant-hit" "RUN"   absent   # <- and the reverse direction

# --- (b) macOS /var vs /private/var: exercise whatever symlink layer the
#         host's OWN tmp path already has. mktemp -d on macOS returns a path
#         under /var/folders/..., itself a symlink to /private/var/folders/...
#         Skips cleanly (not a failure) on hosts where TMP is symlink-free
#         (Linux CI, where the (a) suite above is the portable equivalent).
#         Granted root is a DEDICATED subdirectory, not $TMP itself — $TMP
#         also holds this script's own volatile `$TMP/out` redirects, and
#         the coarse `tree:` floor would otherwise see THOSE change
#         between runs, which is real but not what this test is isolating. ---
VARDIR="$TMP/vardir"
mkdir -p "$VARDIR"
REALVARDIR=$(cd "$VARDIR" && pwd -P)
if [ "$REALVARDIR" != "$VARDIR" ]; then
  printf 'DATA2\n' > "$VARDIR/varin.txt"
  cat > "$TMP/varbuild.pp" <<EOF
perform log(force(node {
  perform log("RUN")
  hash-map-get(perform run("sh", "-c", "cat $VARDIR/varin.txt"), "out")
}))
EOF
  rm -rf "$TMP/.pp"
  run --grant process --grant "fs:$VARDIR:ro" "$TMP/varbuild.pp"
  assert "b-cold-varpath-miss" "RUN"   present
  assert "b-cold-varpath-data" "DATA2" present
  run --grant process --grant "fs:$REALVARDIR:ro" "$TMP/varbuild.pp"
  assert "b-privatevar-grant-hit" "RUN" absent   # /var grant covers a /private/var-observed cell
else
  echo "ok   b-skipped-no-var-symlink-on-this-host ($VARDIR already symlink-free)"
fi

# --- (c) trailing-slash grant == no-trailing-slash grant, both directions ---
rm -rf "$TMP/.pp"
run --grant process --grant "fs:$SRC/:ro" "$TMP/build.pp"
assert "c-cold-trailing-slash-miss" "RUN"   present
assert "c-cold-trailing-slash-data" "DATA1" present
run --grant process --grant "fs:$SRC:ro" "$TMP/build.pp"
assert "c-no-slash-hit" "RUN" absent

rm -rf "$TMP/.pp"
run --grant process --grant "fs:$SRC:ro" "$TMP/build.pp"
assert "c-cold-no-slash-miss" "RUN" present
run --grant process --grant "fs:$SRC/:ro" "$TMP/build.pp"
assert "c-trailing-slash-hit" "RUN" absent

# --- (d) a write-target's cell-id is stable across the file's creation:
#         canonicalizing "$NEWDIR/newfile.txt" before and after the file
#         exists produces the IDENTICAL cell-id string in `pp graph`. ---
NEWDIR="$TMP/newdir"
mkdir -p "$NEWDIR"
TARGET="$NEWDIR/newfile.txt"
cat > "$TMP/stat.pp" <<EOF
force(node { file-exists?("$TARGET") })
EOF

rm -rf "$TMP/.pp"
run --grant "fs:$NEWDIR:ro" "$TMP/stat.pp"
"$PP" graph > "$TMP/graph1" 2>&1
CELL1=$(grep -oE 'stat:[^ ]*newfile\.txt' "$TMP/graph1" | head -1)

printf 'X' > "$TARGET"
run --grant "fs:$NEWDIR:ro" "$TMP/stat.pp"
"$PP" graph > "$TMP/graph2" 2>&1
CELL2=$(grep -oE 'stat:[^ ]*newfile\.txt' "$TMP/graph2" | head -1)

if [ -n "$CELL1" ] && [ "$CELL1" = "$CELL2" ]; then
  echo "ok   d-write-target-cell-stable ($CELL1)"
else
  echo "FAIL d-write-target-cell-stable: before='$CELL1' after='$CELL2'"
  fail=1
fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== CANONICAL CELLS (LAW 23) TEST PASSED ==="; fi
exit $fail
