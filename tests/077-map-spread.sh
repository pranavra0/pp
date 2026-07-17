#!/usr/bin/env bash
# tests/077 — B3: map update/merge via spread `{ ...m, k -> v }`.
#
# Replaces the removed `{ base | k -> v }` update form. Semantics:
#   { ...m, k -> v }         insert/overwrite into a copy of m
#   { ...defaults, ...over } merge, rightmost wins
# A spread-free literal keeps its `(hash-map …)` lowering (hash-preserving).
# Map spread is a quasiquote exclusion (SPEC B.7) — it must error cleanly.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got
  got=$("$PP" "$file" 2>&1)
  if [ "$got" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "got: $(printf '%q' "$got")"
  fi
}

# (a) update: overwrite one key, original unchanged. Order-independent via get.
cat > "$TMP/update.pp" <<'EOF'
let base = { :a -> 1, :b -> 2 }
let up = { ...base, :b -> 99 }
print([hash-map-get(up, :a), hash-map-get(up, :b), hash-map-get(base, :b)])
EOF
run_ok "map-spread-update" "$TMP/update.pp" '(1 99 2)'

# (b) add a new key while spreading.
cat > "$TMP/add.pp" <<'EOF'
let base = { :a -> 1 }
let added = { ...base, :c -> 3 }
print([hash-map-get(added, :a), hash-map-get(added, :c)])
EOF
run_ok "map-spread-add" "$TMP/add.pp" '(1 3)'

# (c) merge two maps, rightmost wins.
cat > "$TMP/merge.pp" <<'EOF'
let defaults = { :cc -> "gcc", :opt -> 0 }
let over = { :opt -> 2, :warn -> true }
let m = { ...defaults, ...over }
print([hash-map-get(m, :cc), hash-map-get(m, :opt), hash-map-get(m, :warn)])
EOF
run_ok "map-spread-merge-rightmost-wins" "$TMP/merge.pp" '("gcc" 2 true)'

# (d) spread-only copy.
cat > "$TMP/copy.pp" <<'EOF'
let base = { :x -> 10 }
let c = { ...base }
print(hash-map-get(c, :x))
EOF
run_ok "map-spread-copy" "$TMP/copy.pp" '10'

# (e) spread-free literal is unchanged (still a plain map).
cat > "$TMP/plain.pp" <<'EOF'
print({ :a -> 1, :b -> 2 })
EOF
run_ok "plain-map-unchanged" "$TMP/plain.pp" '{:a 1, :b 2}'

# (f) the removed `{ base | k -> v }` update form errors.
cat > "$TMP/old.pp" <<'EOF'
let base = { :a -> 1 }
print({ base | :a -> 2 })
EOF
got=$("$PP" "$TMP/old.pp" 2>&1 || true)
if [[ "$got" == *error* ]]; then
  ok "old-pipe-update-removed"
else
  bad "old-pipe-update-removed" "got: $got"
fi

# (g) map spread inside quasiquote{} is a documented B.7 exclusion: clean error.
cat > "$TMP/qq.pp" <<'EOF'
let m = { :a -> 1 }
print(quasiquote { { ...m } })
EOF
got=$("$PP" "$TMP/qq.pp" 2>&1 || true)
if [[ "$got" == *"not supported inside quasiquote"* ]]; then
  ok "map-spread-qq-excluded"
else
  bad "map-spread-qq-excluded" "got: $got"
fi

# (h) but a plain map literal inside quasiquote{} still works.
cat > "$TMP/qqok.pp" <<'EOF'
print(quasiquote { { :a -> 1, :b -> 2 } })
EOF
run_ok "plain-map-in-qq" "$TMP/qqok.pp" '{:a 1, :b 2}'

exit $fail
