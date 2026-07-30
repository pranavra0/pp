#!/usr/bin/env bash
# tests/080 — lints from `pp lint`:
#   dot-identifier (case B11 below) — an identifier containing '.' (a
#       dot-method trap); grant descriptors (fs.read) lower away, so they
#       never trip it.
#   tagged-value convention (case B12 below) — a function mixing [:err, _]
#       and a bare value across branches; car/cdr applied to a tagged result
#       literal.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# lint FILE, assert the combined stdout+stderr CONTAINS $needle.
warns() {
  local name="$1" file="$2" needle="$3"
  local out; out=$("$PP" lint "$file" 2>&1 || true)
  if [[ "$out" == *"$needle"* ]]; then ok "$name"
  else bad "$name" "expected a warning containing '$needle'" "got: $out"; fi
}
# lint FILE, assert it is CLEAN (no warnings) — needle must be absent.
clean() {
  local name="$1" file="$2"
  local out; out=$("$PP" lint "$file" 2>&1 || true)
  if [[ "$out" == *"no warnings"* ]]; then ok "$name"
  else bad "$name" "expected no warnings" "got: $out"; fi
}
# lint FILE, assert a specific needle is ABSENT (other warnings may exist).
no_needle() {
  local name="$1" file="$2" needle="$3"
  local out; out=$("$PP" lint "$file" 2>&1 || true)
  if [[ "$out" != *"$needle"* ]]; then ok "$name"
  else bad "$name" "did not expect '$needle'" "got: $out"; fi
}


# ---- dot-identifier (case B11) ----
printf 'def f(src) { src.replace-ext(".o") }\n' > "$TMP/b11-dot.pp"
warns "B11-dot-identifier" "$TMP/b11-dot.pp" "contains '.'"
# a `->` conversion name has no dot — must not warn.
printf 'def f(s) { string->number(s) }\n' > "$TMP/b11-arrow.pp"
no_needle "B11-arrow-name-ok" "$TMP/b11-arrow.pp" "contains '.'"
# grant descriptors lower away (cap-restrict), so `fs.read` never trips B11.
printf 'node n() needs fs.read("p") { 1 }\n' > "$TMP/b11-grant.pp"
no_needle "B11-grant-descriptor-ok" "$TMP/b11-grant.pp" "contains '.'"

# ---- tagged-value convention (case B12) ----
printf 'def bad(x) { if x { 42 } else { [:err, "no"] } }\n' > "$TMP/b12-mixed.pp"
warns "B12-mixed-shape" "$TMP/b12-mixed.pp" "inconsistent result shape"
# a consistent [:ok]/[:err] function must not warn.
printf 'def good(x) { if x { [:ok, 42] } else { [:err, "no"] } }\n' > "$TMP/b12-ok.pp"
no_needle "B12-consistent-result-ok" "$TMP/b12-ok.pp" "inconsistent result shape"
printf 'def worse(r) { car([:ok, 5]) }\n' > "$TMP/b12-car.pp"
warns "B12-car-of-result" "$TMP/b12-car.pp" "destructure a result"
# car of a plain (non-tagged) list must not warn.
printf 'def fst(xs) { car([1, 2, 3]) }\n' > "$TMP/b12-carok.pp"
no_needle "B12-car-plain-list-ok" "$TMP/b12-carok.pp" "destructure a result"

rm -rf "$TMP"
exit $fail
