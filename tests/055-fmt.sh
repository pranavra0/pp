#!/usr/bin/env bash
# tests/055 — `pp fmt`: a location-preserving, comment-carrying transpiler
# between the sexpr and brace surfaces, in both directions.
#
#   (a) a tricky-comments fixture (trailing on a def's head line, a
#       standalone comment nested inside a multi-statement body, a
#       comment-only line, a comment right before a closing paren/brace,
#       one at the very end of the file with no trailing newline in the
#       source) round-trips sexpr -> braces -> sexpr: the program still
#       runs identically, every comment's TEXT survives (mod the `;`/`#`
#       delimiter and whitespace) with the same COUNT, and the whole
#       chain's per-form hash (SPEC law 20) matches the original (using
#       `-i` so the location file never changes mid-chain — hash
#       preservation requires the path to stay put, per the `-i` flag's
#       own docstring);
#   (b) the same, starting from a BRACE-authored fixture (`#` comments),
#       braces -> sexpr -> braces;
#   (c) idempotence: `fmt --to-braces`/`--to-sexpr` is deterministic — run
#       twice on the same input, byte-identical stdout;
#   (d) the whole-tree sweep (every .pp in tests/, stdlib/, build.pp,
#       demo/, examples/, docs/manual/**): canonical same-surface rewrite
#       plus stdout-only `to-braces`/`to-sexpr` conversions preserve every
#       top-level form's hash. The brace intermediate re-reading to the same
#       hash as the sexpr original is the same property tests/054's
#       `--check-roundtrip` loop already gates.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT="$PWD"

# comment TEXT content (order-preserving), delimiter/line-number-agnostic:
# `pp --list-comments SURFACE FILE` prints "LINE: TRIMMED-TEXT"; strip the
# "LINE: " prefix so comparisons are purely about which comment texts, and
# how many, survived — never about exact re-flowed position (un-located
# interior statements don't carry their own line at the AST level at all,
# so exact position isn't guaranteed; count + content is what's gated).
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
# extension-based run dispatch — braces use `.pp` — still works; the
# in-place/same-path hash check is done on its own copy below)
if ! "$PP" fmt --to-braces "$TMP/a/fix.ppl" > "$TMP/a/fix.pp" 2>"$TMP/a/e1"; then
  bad "fixture-a-to-braces" "$(cat "$TMP/a/e1")"
else
  ok "fixture-a-to-braces"
fi
if ! "$PP" fmt --to-sexpr "$TMP/a/fix.pp" > "$TMP/a/fix2.ppl" 2>"$TMP/a/e2"; then
  bad "fixture-a-to-sexpr" "$(cat "$TMP/a/e2")"
else
  ok "fixture-a-to-sexpr"
fi

got_pp=$("$PP" "$TMP/a/fix.pp" 2>&1)
got_pp2=$("$PP" "$TMP/a/fix2.ppl" 2>&1)
if [ "$got_pp" = "$expected_run" ] && [ "$got_pp2" = "$expected_run" ]; then
  ok "fixture-a-runs-identically"
else
  bad "fixture-a-runs-identically" "orig: $expected_run" "braces: $got_pp" "sexpr2: $got_pp2"
fi

c_orig=$(comment_texts sexpr "$TMP/a/fix.ppl")
c_pp=$(comment_texts brace "$TMP/a/fix.pp")
c_pp2=$(comment_texts sexpr "$TMP/a/fix2.ppl")
n_orig=$(printf '%s\n' "$c_orig" | grep -c .)
if [ "$c_orig" = "$c_pp" ] && [ "$c_orig" = "$c_pp2" ] && [ "$n_orig" -ge 8 ]; then
  ok "fixture-a-comments-preserved ($n_orig comments)"
else
  bad "fixture-a-comments-preserved" \
    "orig ($n_orig):" "$c_orig" "braces:" "$c_pp" "sexpr2:" "$c_pp2"
fi

# delimiter conversion: the `;;` banner must come out as a SINGLE `#`
# with the delimiter run stripped — a stacked `# ;` means the scan kept
# the source delimiter inside the text (hash gates can't catch this;
# hashes ignore comments by construction)
if grep -q '^# a leading double-semicolon banner comment$' "$TMP/a/fix.pp" \
   && ! grep -qE '(^|[[:space:]])# ;' "$TMP/a/fix.pp"; then
  ok "fixture-a-delimiter-stripped"
else
  bad "fixture-a-delimiter-stripped" "$(head -3 "$TMP/a/fix.pp")"
fi
# noise: no line of the brace output may end in whitespace (which is also
# where a trailing '; ' separator would show up)
if grep -qE '[[:blank:]]$' "$TMP/a/fix.pp"; then
  bad "fixture-a-no-trailing-noise" "$(grep -nE '[[:blank:]]$' "$TMP/a/fix.pp" | head -3)"
else
  ok "fixture-a-no-trailing-noise"
fi

# strict canonical same-surface rewrite (atomic and hash-preserving)
cp "$TMP/a/fix.orig.ppl" "$TMP/a/work.ppl"
if "$PP" fmt "$TMP/a/work.ppl" >"$TMP/a/fmt.out" 2>"$TMP/a/e3" \
   && "$PP" --compare-hash "$TMP/a/work.ppl" "$TMP/a/fix.orig.ppl" >"$TMP/a/e3" 2>&1; then
  ok "fixture-a-hash-preserved"
else
  bad "fixture-a-hash-preserved" "$(cat "$TMP/a/e3")"
fi

# CLI surface guards: canonical in-place formatting is `fmt FILE`, explicit
# conversion is stdout-only, and the round-trip checker/help alias are stable.
if "$PP" --check-roundtrip "$TMP/a/fix.ppl" >"$TMP/a/check.out" 2>"$TMP/a/check.err"; then
  ok "check-roundtrip"
else
  bad "check-roundtrip" "$(cat "$TMP/a/check.err")"
fi
if "$PP" fmt --to-braces "$TMP/a/fix.pp" >"$TMP/a/reject.out" 2>"$TMP/a/reject.err"; then
  bad "to-braces-rejects-brace-input"
else
  ok "to-braces-rejects-brace-input"
fi
if "$PP" fmt --to-sexpr "$TMP/a/fix.ppl" >"$TMP/a/reject.out" 2>"$TMP/a/reject.err"; then
  bad "to-sexpr-rejects-sexpr-input"
else
  ok "to-sexpr-rejects-sexpr-input"
fi
if "$PP" fmt --to-braces "$TMP/a/fix.ppl" -i >"$TMP/a/reject.out" 2>"$TMP/a/reject.err"; then
  bad "formatter-rejects-in-place-option"
else
  ok "formatter-rejects-in-place-option"
fi
"$PP" --help >"$TMP/help-long"
"$PP" -h >"$TMP/help-short"
if cmp -s "$TMP/help-long" "$TMP/help-short"; then
  ok "help-alias"
else
  bad "help-alias" "$(diff "$TMP/help-long" "$TMP/help-short" | head -10)"
fi

# ---- (b) the same, brace-authored (`#` comments) ----
mkdir -p "$TMP/b"
cat > "$TMP/b/fix.pp" <<'EOF'
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
cp "$TMP/b/fix.pp" "$TMP/b/fix.orig.pp"
expected_run_b=$("$PP" "$TMP/b/fix.pp" 2>&1)

if ! "$PP" fmt --to-sexpr "$TMP/b/fix.pp" > "$TMP/b/fix.ppl" 2>"$TMP/b/e1"; then
  bad "fixture-b-to-sexpr" "$(cat "$TMP/b/e1")"
else
  ok "fixture-b-to-sexpr"
fi
if ! "$PP" fmt --to-braces "$TMP/b/fix.ppl" > "$TMP/b/fix2.pp" 2>"$TMP/b/e2"; then
  bad "fixture-b-to-braces" "$(cat "$TMP/b/e2")"
else
  ok "fixture-b-to-braces"
fi

got_pp=$("$PP" "$TMP/b/fix.ppl" 2>&1)
got_pp2=$("$PP" "$TMP/b/fix2.pp" 2>&1)
if [ "$got_pp" = "$expected_run_b" ] && [ "$got_pp2" = "$expected_run_b" ]; then
  ok "fixture-b-runs-identically"
else
  bad "fixture-b-runs-identically" "orig: $expected_run_b" "sexpr: $got_pp" "braces2: $got_pp2"
fi

c_orig_b=$(comment_texts brace "$TMP/b/fix.pp")
c_pp_b=$(comment_texts sexpr "$TMP/b/fix.ppl")
c_pp2=$(comment_texts brace "$TMP/b/fix2.pp")
n_orig_b=$(printf '%s\n' "$c_orig_b" | grep -c .)
if [ "$c_orig_b" = "$c_pp_b" ] && [ "$c_orig_b" = "$c_pp2" ] && [ "$n_orig_b" -ge 8 ]; then
  ok "fixture-b-comments-preserved ($n_orig_b comments)"
else
  bad "fixture-b-comments-preserved" \
    "orig ($n_orig_b):" "$c_orig_b" "sexpr:" "$c_pp_b" "braces2:" "$c_pp2"
fi

# ---- (c) idempotence: deterministic output, run twice ----
"$PP" fmt --to-braces "$TMP/a/fix.orig.ppl" > "$TMP/a/out1.pp" 2>/dev/null
"$PP" fmt --to-braces "$TMP/a/fix.orig.ppl" > "$TMP/a/out2.pp" 2>/dev/null
if diff -q "$TMP/a/out1.pp" "$TMP/a/out2.pp" >/dev/null; then
  ok "idempotent-to-braces"
else
  bad "idempotent-to-braces" "$(diff "$TMP/a/out1.pp" "$TMP/a/out2.pp" | head -10)"
fi
"$PP" fmt --to-sexpr "$TMP/b/fix.orig.pp" > "$TMP/b/out1.ppl" 2>/dev/null
"$PP" fmt --to-sexpr "$TMP/b/fix.orig.pp" > "$TMP/b/out2.ppl" 2>/dev/null
if diff -q "$TMP/b/out1.ppl" "$TMP/b/out2.ppl" >/dev/null; then
  ok "idempotent-to-sexpr"
else
  bad "idempotent-to-sexpr" "$(diff "$TMP/b/out1.ppl" "$TMP/b/out2.ppl" | head -10)"
fi

# ---- (d) whole-tree sweep (canonical rewrite plus both stdout conversions)
# Each file is round-tripped as a private COPY under $TMP, never in the
# shared tree. The canonical rewrite exercises atomic same-surface formatting;
# the two explicit targets exercise stdout-only conversion. ----
sweep_fail=0
sweep_count=0
sweep_comments=0
for f in "$ROOT"/tests/[0-9]*.pp \
         "$ROOT"/tests/mutate-cproject.pp "$ROOT"/stdlib/*.pp \
         "$ROOT"/build.pp "$ROOT"/demo/volatile-deploy.pp "$ROOT"/examples/*.pp \
         "$ROOT"/docs/manual/*.pp "$ROOT"/docs/manual/examples/*.pp; do
  [ -f "$f" ] || continue
  sweep_count=$((sweep_count + 1))
  work="$TMP/sweep-work-$sweep_count.pp"
  backup="$TMP/sweep-orig-$sweep_count.pp"
  mid="$TMP/sweep-mid-$sweep_count.ppl"
  after="$TMP/sweep-after-$sweep_count.pp"
  cp "$f" "$work"; cp "$f" "$backup"
  chmod u+w "$work"
  c_before=$(comment_texts brace "$work")
  n_before=$("$PP" --list-comments brace "$work" 2>/dev/null | wc -l | tr -d ' ')
  if ! "$PP" fmt "$work" >"$TMP/sweep-format.out" 2>"$TMP/sweep.err"; then
    bad "sweep-canonical ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1; continue
  fi
  c_canonical=$(comment_texts brace "$work")
  if [ "$c_before" != "$c_canonical" ]; then
    bad "sweep-canonical-comments ($f)" \
      "before ($n_before):" "$c_before" "after:" "$c_canonical"
    sweep_fail=1
  fi
  if ! "$PP" fmt --to-sexpr "$work" >"$mid" 2>"$TMP/sweep.err"; then
    bad "sweep-to-sexpr ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1; continue
  fi
  c_mid=$(comment_texts sexpr "$mid")
  if ! "$PP" fmt --to-braces "$mid" >"$after" 2>"$TMP/sweep.err"; then
    bad "sweep-to-braces ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1; continue
  fi
  # brace-output quality gates: no line ends in whitespace (also where a
  # trailing '; ' would appear), no stacked '# ;' delimiter
  if grep -qE '[[:blank:]]$' "$after"; then
    bad "sweep-noise ($f)" "$(grep -nE '[[:blank:]]$' "$after" | head -2)"; sweep_fail=1
  fi
  if grep -qE '^# ;|^#;;' "$after"; then
    bad "sweep-stacked-delimiter ($f)" "$(grep -nE '^# ;|^#;;' "$after" | head -2)"; sweep_fail=1
  fi
  c_after=$(comment_texts brace "$after")
  if [ "$c_before" != "$c_mid" ] || [ "$c_before" != "$c_after" ]; then
    bad "sweep-comments ($f)" \
      "before ($n_before):" "$c_before" "sexpr:" "$c_mid" "braces:" "$c_after"
    sweep_fail=1
  fi
  sweep_comments=$((sweep_comments + n_before))
  if ! "$PP" --compare-hash "$after" "$backup" >"$TMP/sweep.err" 2>&1; then
    bad "sweep-hash ($f)" "$(cat "$TMP/sweep.err")"; sweep_fail=1
  fi
done
[ "$sweep_fail" = 0 ] && ok "whole-tree-fmt-roundtrip ($sweep_count files, $sweep_comments comments)"

if [ "$fail" = 0 ]; then
  echo "=== 055 FMT: ALL PASS ==="
  exit 0
else
  exit 1
fi
