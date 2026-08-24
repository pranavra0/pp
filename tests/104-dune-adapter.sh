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

DUNE_PATH=$(command -v dune || true)
if [ -z "$DUNE_PATH" ]; then
  bad "dune-command-available" "Dune is required for the adapter contract"
else
  cat >"$TMP/closed.pp" <<EOF
load("$PWD/stdlib/dune.pp")
let spec = {
  :tool -> {:tree -> {"bin/dune" -> {:kind -> :file, :mode -> 493, :blob -> blob(slurp("$DUNE_PATH"))}}},
  :tool-path -> "bin/dune",
  :target -> "a.out",
  :inputs -> {:tree -> {
    "dune-project" -> {:kind -> :file, :mode -> 420, :blob -> blob("(lang dune 3.0)\n")},
    "dune" -> {:kind -> :file, :mode -> 420, :blob -> blob("(rule (target a.out) (deps a.in) (action (copy %{deps} %{target})))\n")},
    "a.in" -> {:kind -> :file, :mode -> 420, :blob -> blob("A2\n")}
  }},
  :platform -> {"os" -> "linux"},
  :closed-output -> "_build/default/a.out"
}
print(dune-closed-request(spec))
let result = dune-build(:closed-source, spec)
let output = result[:outputs][:tree]["_build/default/a.out"]
print(result[:exit])
print(blob-get(output[:blob]))
EOF
  "$PP" --grant process --grant "fs:$DUNE_PATH:ro" "$TMP/closed.pp" \
    >"$TMP/closed.out" 2>&1
  if ! grep -q -- '"--root" "/in"' "$TMP/closed.out" \
      || ! grep -q '"_build/default/a.out"' "$TMP/closed.out"; then
    bad "dune-closed-immutable-request" "$(cat "$TMP/closed.out")"
  elif grep -q ':exit 0' "$TMP/closed.out" \
      && grep -Fq '"A2\n"' "$TMP/closed.out"; then
    ok "dune-closed-run"
  elif grep -q 'closed Linux runner unavailable' "$TMP/closed.out"; then
    ok "dune-closed-runner-unavailable"
  else
    bad "dune-closed-run" "$(cat "$TMP/closed.out")"
  fi
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
grep -Rni --include='*.lisp' 'dune' "$ROOT/lisp/runtime" \
  >"$TMP/core-dune"
grep_status=$?
case "$grep_status" in
  0) bad "dune-policy-outside-core" "$(cat "$TMP/core-dune")" ;;
  1) ok "dune-policy-outside-core" ;;
  *) bad "dune-policy-check-failed" "grep exit status $grep_status" ;;
esac

if [ "$fail" -eq 0 ]; then echo "=== DUNE ADAPTER TEST PASSED ==="; fi
exit "$fail"
