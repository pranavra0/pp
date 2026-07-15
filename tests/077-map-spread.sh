#!/usr/bin/env bash
# tests/077 — B3: map update/merge via spread `{ ...m, k -> v }`.
#
# Replaces the removed `{ base | k -> v }` update form. Semantics:
#   { ...m, k -> v }         insert/overwrite into a copy of m
#   { ...defaults, ...over } merge, rightmost wins
# A spread-free literal keeps its `(hash-map …)` lowering (hash-preserving).
# Map spread is a quasiquote exclusion (SPEC B.7) — it must error cleanly.
#
# Differential: the tree-walker and the bytecode VM must agree byte for byte.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
run_ok() {
  local name="$1" file="$2" expected="$3"
  local got_tw got_bc
  got_tw=$("$PP"            "$file" 2>&1)
  got_bc=$("$PP" --bytecode "$file" 2>&1)
  if [ "$got_tw" = "$expected" ] && [ "$got_bc" = "$expected" ]; then
    ok "$name"
  else
    bad "$name" "expected: $(printf '%q' "$expected")" \
        "tw: $(printf '%q' "$got_tw")" "bc: $(printf '%q' "$got_bc")"
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

# (f) the removed `{ base | k -> v }` update form errors on both backends.
cat > "$TMP/old.pp" <<'EOF'
let base = { :a -> 1 }
print({ base | :a -> 2 })
EOF
got_tw=$("$PP" "$TMP/old.pp" 2>&1 || true)
got_bc=$("$PP" --bytecode "$TMP/old.pp" 2>&1 || true)
if [[ "$got_tw" == *error* ]] && [[ "$got_bc" == *error* ]]; then
  ok "old-pipe-update-removed"
else
  bad "old-pipe-update-removed" "tw: $got_tw" "bc: $got_bc"
fi

# (g) map spread inside quasiquote{} is a documented B.7 exclusion: clean error.
cat > "$TMP/qq.pp" <<'EOF'
let m = { :a -> 1 }
print(quasiquote { { ...m } })
EOF
got_tw=$("$PP" "$TMP/qq.pp" 2>&1 || true)
got_bc=$("$PP" --bytecode "$TMP/qq.pp" 2>&1 || true)
if [[ "$got_tw" == *"not supported inside quasiquote"* ]] \
   && [[ "$got_bc" == *"not supported inside quasiquote"* ]]; then
  ok "map-spread-qq-excluded"
else
  bad "map-spread-qq-excluded" "tw: $got_tw" "bc: $got_bc"
fi

# (h) but a plain map literal inside quasiquote{} still works.
cat > "$TMP/qqok.pp" <<'EOF'
print(quasiquote { { :a -> 1, :b -> 2 } })
EOF
run_ok "plain-map-in-qq" "$TMP/qqok.pp" '{:a 1, :b 2}'

exit $fail
