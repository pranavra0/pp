#!/usr/bin/env bash
# One pp library interface drives observational and closed immutable Dune
# requests. Dune policy remains outside the runtime.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PROJECT="$TMP/project"
DEST="$TMP/result"
mkdir -p "$PROJECT" "$DEST"

cat >"$PROJECT/dune-project" <<'EOF'
(lang dune 3.0)
EOF
cat >"$PROJECT/dune" <<EOF
(rule
 (target a.out)
 (deps a.in)
 (action (progn
   (run sh -c "printf a >> $PROJECT/action.log")
   (copy %{deps} %{target}))))
(rule
 (target b.out)
 (deps b.in)
 (action (progn
   (run sh -c "printf b >> $PROJECT/action.log")
   (copy %{deps} %{target}))))
EOF
printf 'A1\n' >"$PROJECT/a.in"
printf 'B1\n' >"$PROJECT/b.in"

write_program() {
  cat >"$TMP/build.pp" <<EOF
load("$PWD/stdlib/dune.pp")
let result = dune-build(:working-tree, {
  :root -> "$PROJECT",
  :target -> "a.out",
  :output -> "$PROJECT/_build/default/a.out",
  :name -> "a.out",
  :mode -> 420
})
result[:outputs]
EOF
}
write_program

build() {
  "$PP" --grant process --grant "fs:$PROJECT:ro" \
    --grant "fs:$DEST:wo" --reconcile "$DEST" "$TMP/build.pp" \
    >"$TMP/out" 2>&1
}

build
if [ "$(cat "$DEST/a.out")" = "A1" ]; then ok "dune-working-cold"
else bad "dune-working-cold" "$(cat "$TMP/out")"; fi
actions=$(wc -c <"$PROJECT/action.log")

build
if [ "$(wc -c <"$PROJECT/action.log")" -eq "$actions" ]; then
  ok "dune-null-build-no-actions"
else bad "dune-null-build-no-actions"; fi

printf 'B2\n' >"$PROJECT/b.in"
build
if [ "$(wc -c <"$PROJECT/action.log")" -eq "$actions" ]; then
  ok "dune-unwanted-input-no-action"
else bad "dune-unwanted-input-no-action"; fi

printf 'A2\n' >"$PROJECT/a.in"
build
if [ "$(cat "$DEST/a.out")" = "A2" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq $((actions + 1)) ]; then
  ok "dune-precise-rebuild"
else bad "dune-precise-rebuild" "$(cat "$TMP/out")"; fi

rm -rf "$DEST"
mkdir "$DEST"
before=$(wc -c <"$PROJECT/action.log")
build
if [ "$(cat "$DEST/a.out")" = "A2" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq "$before" ]; then
  ok "dune-artifact-restoration"
else bad "dune-artifact-restoration" "$(cat "$TMP/out")"; fi

cat >"$TMP/closed.pp" <<EOF
load("$PWD/stdlib/dune.pp")
print(dune-closed-request({
  :tool -> {:tree -> {"bin/dune" -> {:kind -> :file, :mode -> 493, :blob -> blob("tool")}}},
  :tool-path -> "bin/dune",
  :target -> "a.out",
  :inputs -> {:tree -> {"a.in" -> {:kind -> :file, :mode -> 420, :blob -> blob("A2\n")}}},
  :platform -> {"os" -> "linux"},
  :closed-output -> "_build/default/a.out"
}))
EOF
"$PP" "$TMP/closed.pp" >"$TMP/closed.out" 2>&1
if grep -q -- '"--root" "/in"' "$TMP/closed.out" \
    && grep -q '"_build/default/a.out"' "$TMP/closed.out"; then
  ok "dune-closed-immutable-request"
else bad "dune-closed-immutable-request" "$(cat "$TMP/closed.out")"; fi

if ! rg -n -i 'dune' src/runtime --glob '*.ml' --glob '*.mli' \
    >"$TMP/core-dune"; then
  ok "dune-policy-outside-core"
else bad "dune-policy-outside-core" "$(cat "$TMP/core-dune")"; fi

if [ "$fail" -eq 0 ]; then echo "=== DUNE ADAPTER TEST PASSED ==="; fi
exit "$fail"
