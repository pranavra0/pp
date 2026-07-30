#!/usr/bin/env bash
# pins: LAW-17 LAW-20 LAW-21 LAW-23 LAW-26 LAW-28 LAW-34
# Fresh and cached node evaluation agree across outcomes, worlds, authority, handlers, children, restarts, and placement.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

normalize() {
  sed '/^\[info\] COMPUTE/d' "$1"
}

agree() {
  local name="$1" grant="$2" schedule="$3"
  shift 3
  "$PP" --no-cache --schedule "$schedule" --grant "$grant" "$@" \
    >"$TMP/$name.fresh" 2>&1
  local fresh_status=$?
  "$PP" --schedule "$schedule" --grant "$grant" "$@" \
    >"$TMP/$name.cached" 2>&1
  local cached_status=$?
  normalize "$TMP/$name.fresh" >"$TMP/$name.fresh.norm"
  normalize "$TMP/$name.cached" >"$TMP/$name.cached.norm"
  if [ "$fresh_status" -eq "$cached_status" ] \
      && diff -u "$TMP/$name.fresh.norm" "$TMP/$name.cached.norm" \
           >"$TMP/$name.diff" \
      && grep -q '^\[info\] COMPUTE' "$TMP/$name.fresh" \
      && ! grep -q '^\[info\] COMPUTE' "$TMP/$name.cached"; then
    ok "$name"
  else
    bad "$name" "fresh status: $fresh_status" "cached status: $cached_status" \
      "$(cat "$TMP/$name.diff")" \
      "fresh: $(cat "$TMP/$name.fresh")" \
      "cached: $(cat "$TMP/$name.cached")"
  fi
}

printf 'one\n' >"$TMP/left"
printf 'child-one\n' >"$TMP/right"

write_program() {
  local handler_result="$1"
  cat >"$TMP/oracle.pp" <<EOF
with-handler(ask = fn(_) { "$handler_result" }) {
  print(force(node {
    log!("COMPUTE")
    let child = force(node {
      string-append("child:", \$file("$TMP/right"))
    })
    let observed = \$file("$TMP/left")
    if observed = "fail\n" {
      car(5)
    } else {
      [observed, child, perform ask(nil)]
    }
  }))
}
EOF
}

write_program "handler-one"
agree success-v1 "fs:$TMP:ro" serial "$TMP/oracle.pp"
printf 'two\n' >"$TMP/left"
agree success-v2 "fs:$TMP:ro" parallel:2 "$TMP/oracle.pp"
printf 'one\n' >"$TMP/left"
agree success-revert "fs:$TMP:ro" serial "$TMP/oracle.pp"

printf 'child-two\n' >"$TMP/right"
agree child-change "fs:$TMP:ro" parallel:2 "$TMP/oracle.pp"
printf 'child-one\n' >"$TMP/right"
agree child-revert "fs:$TMP:ro" serial "$TMP/oracle.pp"

write_program "handler-two"
agree handler-change "fs:$TMP:ro" parallel:2 "$TMP/oracle.pp"
write_program "handler-one"
agree handler-revert "fs:$TMP:ro" serial "$TMP/oracle.pp"

printf 'fail\n' >"$TMP/left"
agree failure "fs:$TMP:ro" serial "$TMP/oracle.pp"
printf 'one\n' >"$TMP/left"
agree failure-input-revert "fs:$TMP:ro" parallel:2 "$TMP/oracle.pp"

"$PP" --grant "fs:$TMP:ro" "$TMP/oracle.pp" >"$TMP/authority-wide" 2>&1
"$PP" --no-cache --grant "fs:$TMP/nowhere:ro" "$TMP/oracle.pp" \
  >"$TMP/authority-fresh" 2>&1
fresh_status=$?
"$PP" --grant "fs:$TMP/nowhere:ro" "$TMP/oracle.pp" \
  >"$TMP/authority-cached" 2>&1
cached_status=$?
normalize "$TMP/authority-fresh" >"$TMP/authority-fresh.norm"
normalize "$TMP/authority-cached" >"$TMP/authority-cached.norm"
if [ "$fresh_status" -ne 0 ] && [ "$fresh_status" -eq "$cached_status" ] \
    && diff -u "$TMP/authority-fresh.norm" "$TMP/authority-cached.norm" \
         >"$TMP/authority.diff" \
    && ! grep -q 'one\|child-one' "$TMP/authority-cached"; then
  ok "authority-denial"
else
  bad "authority-denial" "$(cat "$TMP/authority.diff")" \
    "fresh: $(cat "$TMP/authority-fresh")" \
    "cached: $(cat "$TMP/authority-cached")"
fi

if [ "$fail" -eq 0 ]; then echo "=== NODE ORACLE TEST PASSED ==="; fi
exit "$fail"
