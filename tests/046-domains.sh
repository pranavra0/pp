#!/usr/bin/env bash
# A reconciler "domain" is an observe/diff/apply triple of pp functions
# running under core-enforced discipline, not privileged implementation code.
# This suite proves a third-party toy domain is generic rather than
# fs/proc-special-cased. The kv domain is defined inside each test program
# inside each test program via `register-domain`; it reuses the same trusted
# primitives (tree-observe/materialize-file/remove-file)
# domain-fs.pp uses, because those are generic fs-write-gated mechanics,
# not "belongs to the fs domain".
#
# Exercises: plan caching (a repeated pass across separate process runs
# hits the plan cache — proved via `pp why`); stratification rejection
# (a desired-state computation that reads its own domain); cap threading
# (apply without the grant is a Capability_error, from cap-restrict
# itself); verify-after-write failure surfaced (a deliberately
# under-converging apply); the generic journal intent/done bracket; and
# fenced-after-domains ordering.
#
# Runs under an isolated HOME.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
# this test builds a domain's :namespace prefix from the RAW shell path
# (a third-party domain author's job to canonicalize, mirroring the
# application boundary's path handling in `lisp/app/main.lisp` and the kernel
# `canonical-path` type); a cell id is always recorded canonical, so an
# uncanonicalized namespace prefix would silently never match and the
# stratification check below would be vacuous.
TMP=$(cd "$TMP" && pwd -P)

assert() {  # NAME PATTERN present|absent [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  local got
  if grep -qE "$pat" "$file"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode in $file, got $got"
    echo "--- output ---"; cat "$file"; fail=1
  fi
}

# The kv domain, as a reusable pp fragment: a THIRD-PARTY registration,
# never touching stdlib/domain-fs.pp or domain-proc.pp. $1 = kv directory.
kv_domain_source() {
  local dir="$1"
  cat <<EOF
load("stdlib/list.pp")
load("stdlib/map.pp")

def kv-content-hash(c) { hash-string(c) }

def kv-diff(observed, desired) {
  let (dkeys = map-keys(desired), okeys = map-keys(observed), creates = filter(

fn(k) { nil?(hash-map-get(observed, k)) }, dkeys), existing = filter(
fn(k) { not(nil?(hash-map-get(observed, k))) }, dkeys), updates = filter(
fn(k) {
    not(hash-map-get(observed, k) = kv-content-hash(hash-map-get(desired, k)))
  }, existing), deletes = filter(

fn(k) { nil?(hash-map-get(desired, k)) }, okeys), items = append(map(

fn(k) { {:kind -> "create", :key -> k, :value -> hash-map-get(desired, k)} }, creates), append(map(

fn(k) { {:kind -> "update", :key -> k, :value -> hash-map-get(desired, k)} }, updates), map(
fn(k) { {:kind -> "delete", :key -> k, :value -> nil} }, deletes)))) {
    {:items -> items, :summary -> [[:created, number->string(length(creates))], [:updated, number->string(length(updates))], [:deleted, number->string(length(deletes))]]}
  }
}


def kv-apply(plan) { each(
fn(item) {
    let (k = hash-map-get(item, :key), path = string-append("$dir/", k)) {
      if hash-map-get(item, :kind) = "delete" { perform remove-file(path) } else {
        perform materialize-file(path, hash-map-get(item, :value))
      }
    }
  }, hash-map-get(plan, :items))
}
def register-kv-domain() {
  register-domain({:name -> "kv", :namespace -> vec[string-append("file:", "$dir"), string-append("tree:", "$dir")], :observe -> (


fn() { perform tree-observe("$dir") }), :diff -> kv-diff, :apply -> kv-apply, :write-cap -> cap-restrict(current-capabilities(), "$dir", :wo)})
}
EOF
}

run() { "$PP" "$@" > "$TMP/out" 2>&1; }

# =====================================================================
# (1) cap threading: apply without the grant is a Capability_error —
#     cap-restrict itself refuses before the domain ever runs, register-
#     domain never sees a widened cap (SPEC law 22).
# =====================================================================
KV1="$TMP/kv1"
{ kv_domain_source "$KV1"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"a" -> "1"}}
}
EOF
} > "$TMP/nogrant.pp"
rm -rf "$TMP/.pp"
run "$TMP/nogrant.pp"
assert "cap-threading-denied" "apability" present
if [ -e "$KV1/a" ]; then echo "FAIL cap-threading-no-write: a materialized without a grant"; fail=1
else echo "ok   cap-threading-no-write"; fi

# =====================================================================
# (2) cold pass creates the tree; generic journal bracket; plan caching
#     across two SEPARATE process invocations (proved via `pp why`).
# =====================================================================
KV2="$TMP/kv2"
{ kv_domain_source "$KV2"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"a" -> "1", "b" -> "2"}}
}
EOF
} > "$TMP/kv.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$KV2:wo" "$TMP/kv.pp"
assert "cold-created" "created=2" present
[ -f "$KV2/a" ] && [ "$(cat "$KV2/a")" = "1" ] && [ -f "$KV2/b" ] && [ "$(cat "$KV2/b")" = "2" ] \
  && echo "ok   cold-files" || { echo "FAIL cold-files"; fail=1; }
if [ -f "$TMP/.pp/store/journal/log" ] && grep -q "intent" "$TMP/.pp/store/journal/log" \
   && grep -q "done" "$TMP/.pp/store/journal/log"; then
  echo "ok   journal-generic-bracket"
else
  echo "FAIL journal-generic-bracket: journal missing intent/done"; fail=1
fi

# Second, separate `pp` process, unchanged desired state: the plan for
# THIS pass's initial diff is the exact plan the FIRST run's verify step
# already computed and cached (same diff-code/observed/desired hashes) —
# a cross-process cache hit, not merely an in-process one.
"$PP" why --grant "fs:$KV2:wo" "$TMP/kv.pp" > "$TMP/why-out" 2>&1
assert "plan-cache-hit" "domain kv: plan .*: hit" present "$TMP/why-out"
assert "null-created" "created=0" present "$TMP/why-out"
assert "null-updated" "updated=0" present "$TMP/why-out"
assert "null-deleted" "deleted=0" present "$TMP/why-out"
# =====================================================================
# (3) descriptor-safe materialize/remove: parent symlinks escaping the
#     grant are rejected, while final symlink objects may be replaced or
#     removed without touching their outside targets.
# =====================================================================
SAFE_ROOT="$TMP/safe-root"
SAFE_OUTSIDE="$TMP/safe-outside"
mkdir -p "$SAFE_ROOT" "$SAFE_OUTSIDE"

# A parent symlink resolves outside the authorized root.  The apply path
# must reject this before writing the outside target.
mkdir -p "$SAFE_OUTSIDE/parent"
ln -s "$SAFE_OUTSIDE/parent" "$SAFE_ROOT/parent"
{ kv_domain_source "$SAFE_ROOT"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"parent/escaped" -> "must-not-write"}}
}
EOF
} > "$TMP/parent-symlink.pp"
rm -rf "$TMP/.pp"
if run --grant "fs:$SAFE_ROOT:wo" "$TMP/parent-symlink.pp"; then
  echo "FAIL parent-symlink-rejected: apply unexpectedly succeeded"; fail=1
else
  assert "parent-symlink-rejected" "apability|outside|invalid|denied|anonical" present
fi
if [ ! -e "$SAFE_OUTSIDE/parent/escaped" ]; then
  echo "ok   parent-symlink-outside-untouched"
else
  echo "FAIL parent-symlink-outside-untouched: escaped file exists"; fail=1
fi

# A final symlink is canonicalized through its target and therefore
# rejected by the capability check; neither object nor target may change.
printf 'outside-original' > "$SAFE_OUTSIDE/final-target"
ln -s "$SAFE_OUTSIDE/final-target" "$SAFE_ROOT/final"
{ kv_domain_source "$SAFE_ROOT"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"final" -> "inside-value"}}
}
EOF
} > "$TMP/final-symlink.pp"
rm -rf "$TMP/.pp"
if run --grant "fs:$SAFE_ROOT:wo" "$TMP/final-symlink.pp"; then
  echo "FAIL final-symlink-materialize-denied: apply unexpectedly succeeded"; fail=1
else
  assert "final-symlink-materialize-denied" "apability|outside|invalid|denied|anonical" present
fi
if [ -L "$SAFE_ROOT/final" ] \
   && [ "$(cat "$SAFE_OUTSIDE/final-target")" = "outside-original" ]; then
  echo "ok   final-symlink-materialize-untouched"
else
  echo "FAIL final-symlink-materialize-untouched"; fail=1
fi

# Removal of a final symlink is likewise rejected; the link and target stay.
printf 'outside-delete-target' > "$SAFE_OUTSIDE/delete-target"
ln -s "$SAFE_OUTSIDE/delete-target" "$SAFE_ROOT/delete"
{ kv_domain_source "$SAFE_ROOT"
  cat <<EOF
do {
  register-domain({:name -> "kv", :namespace -> vec[string-append("file:", "$SAFE_ROOT"), string-append("tree:", "$SAFE_ROOT")], :observe -> (
fn() { {"delete" -> hash-string("observed")} }), :diff -> kv-diff, :apply -> kv-apply, :write-cap -> cap-restrict(current-capabilities(), "$SAFE_ROOT", :wo)})
  {"kv" -> {}}
}
EOF
} > "$TMP/remove-symlink.pp"
rm -rf "$TMP/.pp"
if run --grant "fs:$SAFE_ROOT:wo" "$TMP/remove-symlink.pp"; then
  echo "FAIL final-symlink-remove-denied: apply unexpectedly succeeded"; fail=1
else
  assert "final-symlink-remove-denied" "apability|outside|invalid|denied|anonical" present
fi
if [ -L "$SAFE_ROOT/delete" ] \
   && [ "$(cat "$SAFE_OUTSIDE/delete-target")" = "outside-delete-target" ]; then
  echo "ok   final-symlink-remove-untouched"
else
  echo "FAIL final-symlink-remove-untouched"; fail=1
fi

# Deleting the last nested file prunes empty nested parents, but not the
# authorized root itself.
NESTED_ROOT="$TMP/nested-root"
mkdir -p "$NESTED_ROOT"
{ kv_domain_source "$NESTED_ROOT"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"one/two/leaf" -> "nested"}}
}
EOF
} > "$TMP/nested-create.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$NESTED_ROOT:wo" "$TMP/nested-create.pp"
{ kv_domain_source "$NESTED_ROOT"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {}}
}
EOF
} > "$TMP/nested-remove.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$NESTED_ROOT:wo" "$TMP/nested-remove.pp"
if [ ! -e "$NESTED_ROOT/one" ] && [ -d "$NESTED_ROOT" ]; then
  echo "ok   nested-empty-parents-pruned-root-kept"
else
  echo "FAIL nested-empty-parents-pruned-root-kept"; fail=1
fi


# =====================================================================
# (4) stratification: a desired-state computation that reads its OWN
#     domain is refused (SPEC law 30), generalized to a domain pp's own
#     stdlib never defines.
# =====================================================================
KV3="$TMP/kv3"
mkdir -p "$KV3"
printf 'seed' > "$KV3/seed"
{ kv_domain_source "$KV3"
  cat <<EOF
do {
  register-kv-domain()
  {"kv" -> {"a" -> slurp("$KV3/seed")}}
}
EOF
} > "$TMP/strat.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$KV3:wo" --grant "fs:$KV3:ro" "$TMP/strat.pp"
assert "stratification-rejected" "tratification" present
[ -e "$KV3/a" ] && { echo "FAIL stratification-untouched: a materialized anyway"; fail=1; } \
  || echo "ok   stratification-untouched"

# =====================================================================
# (5) verify-after-write failure surfaced: a domain whose apply
#     deliberately under-converges (a no-op) must fail loudly, not
#     silently accept a still-diverged domain.
# =====================================================================
KV4="$TMP/kv4"
{ kv_domain_source "$KV4"
  cat <<EOF
def register-broken-kv-domain() {
  register-domain({:name -> "kv", :namespace -> vec[string-append("file:", "$KV4"), string-append("tree:", "$KV4")], :observe -> (


fn() { perform tree-observe("$KV4") }), :diff -> kv-diff, :apply -> (

fn(plan) { nil }), :write-cap -> cap-restrict(current-capabilities(), "$KV4", :wo)})
}
do {
  register-broken-kv-domain()
  {"kv" -> {"a" -> "1"}}
}
EOF
} > "$TMP/broken.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$KV4:wo" "$TMP/broken.pp"
assert "verify-after-write-surfaced" "verify-after-write failed for domain kv" present
if [ -e "$KV4/a" ]; then echo "FAIL verify-broken-no-write: apply was a no-op yet a exists"; fail=1
else echo "ok   verify-broken-no-write"; fi

# =====================================================================
# (6) fenced-after-domains ordering: a fenced action registered in the
#     SAME program runs after the domain's own converge/verify, and its
#     journal entries land AFTER the domain's in the log.
# =====================================================================
KV5="$TMP/kv5"
MARKER="$TMP/fenced-marker"
rm -f "$MARKER"
{ kv_domain_source "$KV5"
  cat <<EOF
do {
  register-kv-domain()
  fenced("touch-marker", {"run" -> ["/usr/bin/touch", "$MARKER"]})
  {"kv" -> {"a" -> "1"}}
}
EOF
} > "$TMP/fenced.pp"
rm -rf "$TMP/.pp"
run --grant "fs:$KV5:wo" "$TMP/fenced.pp"
[ -f "$MARKER" ] && echo "ok   fenced-ran" || { echo "FAIL fenced-ran: marker missing"; fail=1; }
JOURNAL="$TMP/.pp/store/journal/log"
if [ -f "$JOURNAL" ]; then
  DOMAIN_LINE=$(grep -n "^intent " "$JOURNAL" | grep -v fenced | tail -1 | cut -d: -f1)
  FENCED_LINE=$(grep -n "^intent fenced" "$JOURNAL" | head -1 | cut -d: -f1)
  if [ -n "$DOMAIN_LINE" ] && [ -n "$FENCED_LINE" ] && [ "$FENCED_LINE" -gt "$DOMAIN_LINE" ]; then
    echo "ok   fenced-after-domains-ordering"
  else
    echo "FAIL fenced-after-domains-ordering: domain=$DOMAIN_LINE fenced=$FENCED_LINE"; fail=1
  fi
else
  echo "FAIL fenced-after-domains-ordering: no journal"; fail=1
fi


 # =====================================================================
 # (6) corrupt domain state aborts observe before diff/apply.
 # =====================================================================
 STATE_DOMAIN="state-probe"
 STATE_KEY="key"
 STATE_HASH=$(printf '%s' "$STATE_KEY" | sha256sum | cut -d' ' -f1)
 STATE_DIR="$TMP/.pp/store/domain-state/$STATE_DOMAIN"
 STATE_SENTINEL="$TMP/state-apply-sentinel"
 rm -rf "$TMP/.pp" "$STATE_SENTINEL"
 mkdir -p "$STATE_DIR"
 printf 'not-a-codec-value' > "$STATE_DIR/$STATE_HASH"
 cat > "$TMP/corrupt-state.pp" <<EOF
do {
  register-domain({:name -> "$STATE_DOMAIN", :namespace -> vec["file:$TMP/state-probe"], :observe -> (
fn() { perform domain-state-get("$STATE_KEY") }), :diff -> (
fn(observed, desired) { {"items" -> [1]} }), :apply -> (
fn(plan) { perform write-file("$STATE_SENTINEL", "leak") }), :write-cap -> cap-restrict(current-capabilities(), "$TMP", :wo)})
  {"$STATE_DOMAIN" -> {"wanted" -> "value"}}
}
EOF
run --grant "fs:$TMP:wo" "$TMP/corrupt-state.pp"
assert "domain-state-corrupt" "corrupt state" present
if [ -e "$STATE_SENTINEL" ]; then echo "FAIL domain-state-no-apply"; fail=1
else echo "ok   domain-state-no-diff-apply"; fi

rm -rf "$TMP"
if [ "$fail" -eq 0 ]; then echo "=== DOMAINS (Q13) TEST PASSED ==="; fi
exit $fail
