#!/usr/bin/env bash
# tests/055 — M7 S2: `pp fmt` (docs/M7-SYNTAX.md "S2 — pp fmt"), the
# location-preserving, comment-carrying transpiler both directions.
#
#   (a) a tricky-comments fixture (trailing on a def's head line, a
#       standalone comment nested inside a multi-statement body, a
#       comment-only line, a comment right before a closing paren/brace,
#       one at the very end of the file with no trailing newline in the
#       source) round-trips sexpr -> braces -> sexpr: the program still
#       runs identically, every comment's TEXT survives (mod the `;`/`#`
#       delimiter and whitespace) with the same COUNT, and the whole
#       chain's per-form LAW-20 hash matches the original (using `-i` so
#       the location file never changes mid-chain — the exact contract
#       docs/M7-SYNTAX.md's S2 section and the `-i` flag's own docstring
#       both hinge on: hash preservation requires the path to stay put);
#   (b) the same, starting from a BRACE-authored fixture (`#` comments),
#       braces -> sexpr -> braces;
#   (c) idempotence: `fmt --to-braces`/`--to-sexpr` is deterministic — run
#       twice on the same input, byte-identical stdout;
#   (d) the whole-tree sweep (every .pp in tests/, stdlib/, build.pp,
#       demo/, examples/, docs/manual/**): `to-braces` then `to-sexpr`,
#       in place (same path both hops — mutates the dune-sandboxed copy
#       tests run against, never the developer's real tree; restored
#       immediately after each file so later tests in this same run see
#       pristine sources), preserves every top-level form's LAW-20 hash.
#       (Exit criterion 3 — the brace intermediate re-reading to the same
#       hash as the sexpr original — is the same property tests/054's
#       existing whole-tree `--roundtrip-braces` loop already gates.)
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac
ROOT="$PWD"
TMP=$(mktemp -d)
export HOME="$TMP"
fail=0

ok()  { echo "ok   $1"; }
bad() { echo "FAIL $1"; shift; for m in "$@"; do echo "     $m"; done; fail=1; }

# comment TEXT content (order-preserving), delimiter/line-number-agnostic:
# `pp --list-comments SURFACE FILE` prints "LINE: TRIMMED-TEXT"; strip the
# "LINE: " prefix so comparisons are purely about which comment texts, and
# how many, survived — never about exact re-flowed position (un-located
# interior statements don't carry their own line at the AST level at all,
# so exact position isn't part of the M7 contract; count + content is —
# docs/M7-SYNTAX.md "Risks / residuals").
comment_texts() { "$PP" --list-comments "$1" "$2" 2>/dev/null | sed -E 's/^[0-9]+: //'; }

# ---- (a) tricky-comments fixture, sexpr-authored ----
mkdir -p "$TMP/a"
cat > "$TMP/a/fix.ppl" <<'EOF'
;; a leading double-semicolon banner comment
(def (f x) ; trailing on the def's own head line
  ; a standalone comment nested inside a multi-statement body
  (print x) ; trailing on the first body statement
  (+ x 1)) ; trailing right before the closing paren

; a comment-only line, alone, between top-level forms

(def (g y z)
  (let [a 1 ; trailing mid binding-vector
        b 2] ; trailing on the binding vector's close
    (+ a b))) ; trailing on final close

(print (f 1)) ; trailing on the final statement
(print (g 2 3))
; a trailing standalone comment at the very end of the file
EOF
cp "$TMP/a/fix.ppl" "$TMP/a/fix.orig.ppl"
expected_run=$("$PP" "$TMP/a/fix.ppl" 2>&1)

# functional + comment chain (separately-named files at each hop, so the
# extension-based run dispatch — braces need `.ppb` — still works; the
# in-place/same-path hash check is done on its own copy below)
if ! "$PP" fmt --to-braces "$TMP/a/fix.ppl" > "$TMP/a/fix.ppb" 2>"$TMP/a/e1"; then
  bad "fixture-a-to-braces" "$(cat "$TMP/a/e1")"
else
  ok "fixture-a-to-braces"
fi
if ! "$PP" fmt --to-sexpr "$TMP/a/fix.ppb" > "$TMP/a/fix2.ppl" 2>"$TMP/a/e2"; then
  bad "fixture-a-to-sexpr" "$(cat "$TMP/a/e2")"
else
  ok "fixture-a-to-sexpr"
fi

got_ppb=$("$PP" "$TMP/a/fix.ppb" 2>&1)
got_pp2=$("$PP" "$TMP/a/fix2.ppl" 2>&1)
if [ "$got_ppb" = "$expected_run" ] && [ "$got_pp2" = "$expected_run" ]; then
  ok "fixture-a-runs-identically"
else
  bad "fixture-a-runs-identically" "orig: $expected_run" "braces: $got_ppb" "sexpr2: $got_pp2"
fi

c_orig=$(comment_texts sexpr "$TMP/a/fix.ppl")
c_ppb=$(comment_texts brace "$TMP/a/fix.ppb")
c_pp2=$(comment_texts sexpr "$TMP/a/fix2.ppl")
n_orig=$(printf '%s\n' "$c_orig" | grep -c .)
if [ "$c_orig" = "$c_ppb" ] && [ "$c_orig" = "$c_pp2" ] && [ "$n_orig" -ge 8 ]; then
  ok "fixture-a-comments-preserved ($n_orig comments)"
else
  bad "fixture-a-comments-preserved" \
    "orig ($n_orig):" "$c_orig" "braces:" "$c_ppb" "sexpr2:" "$c_pp2"
fi

# delimiter conversion: the `;;` banner must come out as a SINGLE `#`
# with the delimiter run stripped — a stacked `# ;` means the scan kept
# the source delimiter inside the text (hash gates can't catch this;
# hashes ignore comments by construction)
if grep -q '^# a leading double-semicolon banner comment$' "$TMP/a/fix.ppb" \
   && ! grep -qE '(^|[[:space:]])# ;' "$TMP/a/fix.ppb"; then
  ok "fixture-a-delimiter-stripped"
else
  bad "fixture-a-delimiter-stripped" "$(head -3 "$TMP/a/fix.ppb")"
fi
# noise: no line of the brace output may end in whitespace (which is also
# where a trailing '; ' separator would show up)
if grep -qE '[[:blank:]]$' "$TMP/a/fix.ppb"; then
  bad "fixture-a-no-trailing-noise" "$(grep -nE '[[:blank:]]$' "$TMP/a/fix.ppb" | head -3)"
else
  ok "fixture-a-no-trailing-noise"
fi

# strict same-path (-i) hash check
cp "$TMP/a/fix.orig.ppl" "$TMP/a/work.ppl"
if "$PP" fmt --to-braces "$TMP/a/work.ppl" -i 2>"$TMP/a/e3" \
   && "$PP" fmt --to-sexpr "$TMP/a/work.ppl" -i 2>>"$TMP/a/e3" \
   && "$PP" --compare-hash "$TMP/a/work.ppl" "$TMP/a/fix.orig.ppl" >"$TMP/a/e3" 2>&1; then
  ok "fixture-a-hash-preserved"
else
  bad "fixture-a-hash-preserved" "$(cat "$TMP/a/e3")"
fi

# ---- (b) the same, brace-authored (`#` comments) ----
mkdir -p "$TMP/b"
cat > "$TMP/b/fix.ppb" <<'EOF'
# a leading standalone comment
def f(x) { # trailing on the def's own head line
  # a standalone comment nested inside a multi-statement body
  print(x) # trailing on the first body statement
  x + 1 # trailing right before the closing brace
}

# a comment-only line, alone, between top-level forms

def g(y, z) {
  let a = 1 # trailing on a let binding
  let b = 2 # trailing on the next let binding
  a + b # trailing on final close
}

print(f(1)) # trailing on the final statement
print(g(2, 3))
# a trailing standalone comment at the very end of the file
EOF
cp "$TMP/b/fix.ppb" "$TMP/b/fix.orig.ppb"
expected_run_b=$("$PP" "$TMP/b/fix.ppb" 2>&1)

if ! "$PP" fmt --to-sexpr "$TMP/b/fix.ppb" > "$TMP/b/fix.ppl" 2>"$TMP/b/e1"; then
  bad "fixture-b-to-sexpr" "$(cat "$TMP/b/e1")"
else
  ok "fixture-b-to-sexpr"
fi
if ! "$PP" fmt --to-braces "$TMP/b/fix.ppl" > "$TMP/b/fix2.ppb" 2>"$TMP/b/e2"; then
  bad "fixture-b-to-braces" "$(cat "$TMP/b/e2")"
else
  ok "fixture-b-to-braces"
fi

got_pp=$("$PP" "$TMP/b/fix.ppl" 2>&1)
got_ppb2=$("$PP" "$TMP/b/fix2.ppb" 2>&1)
if [ "$got_pp" = "$expected_run_b" ] && [ "$got_ppb2" = "$expected_run_b" ]; then
  ok "fixture-b-runs-identically"
else
  bad "fixture-b-runs-identically" "orig: $expected_run_b" "sexpr: $got_pp" "braces2: $got_ppb2"
fi

c_orig_b=$(comment_texts brace "$TMP/b/fix.ppb")
c_pp_b=$(comment_texts sexpr "$TMP/b/fix.ppl")
c_ppb2=$(comment_texts brace "$TMP/b/fix2.ppb")
n_orig_b=$(printf '%s\n' "$c_orig_b" | grep -c .)
if [ "$c_orig_b" = "$c_pp_b" ] && [ "$c_orig_b" = "$c_ppb2" ] && [ "$n_orig_b" -ge 8 ]; then
  ok "fixture-b-comments-preserved ($n_orig_b comments)"
else
  bad "fixture-b-comments-preserved" \
    "orig ($n_orig_b):" "$c_orig_b" "sexpr:" "$c_pp_b" "braces2:" "$c_ppb2"
fi

# ---- (c) idempotence: deterministic output, run twice ----
"$PP" fmt --to-braces "$TMP/a/fix.orig.ppl" > "$TMP/a/out1.ppb" 2>/dev/null
"$PP" fmt --to-braces "$TMP/a/fix.orig.ppl" > "$TMP/a/out2.ppb" 2>/dev/null
if diff -q "$TMP/a/out1.ppb" "$TMP/a/out2.ppb" >/dev/null; then
  ok "idempotent-to-braces"
else
  bad "idempotent-to-braces" "$(diff "$TMP/a/out1.ppb" "$TMP/a/out2.ppb" | head -10)"
fi
"$PP" fmt --to-sexpr "$TMP/b/fix.orig.ppb" > "$TMP/b/out1.ppl" 2>/dev/null
"$PP" fmt --to-sexpr "$TMP/b/fix.orig.ppb" > "$TMP/b/out2.ppl" 2>/dev/null
if diff -q "$TMP/b/out1.ppl" "$TMP/b/out2.ppl" >/dev/null; then
  ok "idempotent-to-sexpr"
else
  bad "idempotent-to-sexpr" "$(diff "$TMP/b/out1.ppl" "$TMP/b/out2.ppl" | head -10)"
fi

# ---- (d) whole-tree sweep (M7 S3: the tree is brace-authored now, so the
#      direction is to-sexpr + to-braces), in place, same path
#      throughout (so `assert`'s baked `at file:line` message — a STRING
#      VALUE inside the hashed expression, not just location metadata —
#      matches too), hash-compared against a saved-before-mutation copy,
#      then restored so later tests in this run see pristine sources.
#      Comment COUNT + TEXT (delimiter/whitespace-agnostic) are checked at
#      BOTH hops too: hashes ignore comments by construction, so hash
#      equality alone can't catch a dropped one (docs/M7-SYNTAX.md
#      "Risks / residuals" — this is the S3 gate). ----
sweep_fail=0
sweep_count=0
sweep_comments=0
for f in "$ROOT"/tests/[0-9]*.pp "$ROOT"/tests/gen-cproject.pp \
         "$ROOT"/tests/mutate-cproject.pp "$ROOT"/stdlib/*.pp \
         "$ROOT"/build.pp "$ROOT"/demo/*.pp "$ROOT"/examples/*.pp \
         "$ROOT"/docs/manual/*.pp "$ROOT"/docs/manual/examples/*.pp; do
  [ -f "$f" ] || continue
  sweep_count=$((sweep_count + 1))
  backup="$TMP/sweep-$sweep_count.pp"
  cp "$f" "$backup"
  # dune's sandboxed source_tree deps are read-only (a correctness guard
  # against rules silently depending on mutated state); this sweep's own
  # mutate-then-restore is self-contained, so make the copy writable for
  # its duration — permission bits aren't part of what gets restored,
  # only content (the sandbox is rebuilt from the real tree next run
  # regardless).
  orig_mode=$(stat -f%Lp "$f" 2>/dev/null || stat -c%a "$f" 2>/dev/null || echo "")
  chmod u+w "$f" 2>/dev/null || true
  c_before=$(comment_texts brace "$f")
  # count every comment, including delimiter-only lines whose content is
  # empty after stripping (`#` separators) — those still must survive
  n_before=$("$PP" --list-comments brace "$f" 2>/dev/null | wc -l | tr -d ' ')
  if ! "$PP" fmt --to-sexpr "$f" -i 2>"$TMP/sweep.err"; then
    bad "sweep-to-sexpr ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1
    cp "$backup" "$f"; continue
  fi
  c_mid=$(comment_texts sexpr "$f")
  if ! "$PP" fmt --to-braces "$f" -i 2>"$TMP/sweep.err"; then
    bad "sweep-to-braces ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1
    cp "$backup" "$f"; continue
  fi
  # brace-output quality gates: no line ends in whitespace (also where a
  # trailing '; ' would appear), no stacked '# ;' delimiter
  if grep -qE '[[:blank:]]$' "$f"; then
    bad "sweep-noise ($f)" "$(grep -nE '[[:blank:]]$' "$f" | head -2)"; sweep_fail=1
  fi
  if grep -qE '^# ;|^#;;' "$f"; then
    bad "sweep-stacked-delimiter ($f)" "$(grep -nE '^# ;|^#;;' "$f" | head -2)"; sweep_fail=1
  fi
  c_after=$(comment_texts brace "$f")
  if [ "$c_before" != "$c_mid" ] || [ "$c_before" != "$c_after" ]; then
    bad "sweep-comments ($f)" \
      "before ($n_before):" "$c_before" "braces:" "$c_mid" "after:" "$c_after"
    sweep_fail=1
  fi
  sweep_comments=$((sweep_comments + n_before))
  if ! "$PP" --compare-hash "$f" "$backup" >"$TMP/sweep.err" 2>&1; then
    bad "sweep-hash ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1
  fi
  cp "$backup" "$f"
  [ -n "$orig_mode" ] && chmod "$orig_mode" "$f" 2>/dev/null || true
done
[ "$sweep_fail" = 0 ] && ok "whole-tree-fmt-roundtrip ($sweep_count files, $sweep_comments comments)"

if [ "$fail" = 0 ]; then
  echo "=== 055 FMT: ALL PASS ==="
  exit 0
else
  exit 1
fi
