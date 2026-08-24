#!/usr/bin/env bash
# The process adapter can drive a real SBCL oracle without making SBCL policy
# part of the evaluator.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

PROJECT="$TMP/project"
DEST="$TMP/result"
mkdir -p "$PROJECT" "$DEST"

SBCL_PATH=$(command -v sbcl || true)
if [ -z "$SBCL_PATH" ]; then
  echo "skip 104-sbcl-adapter: sbcl not found on PATH"
  exit 0
fi

cat >"$PROJECT/build.lisp" <<'EOF'
(let* ((root (second sb-ext:*posix-argv*))
       (input (concatenate 'string root "/a.in"))
       (output (concatenate 'string root "/_build/default/a.out"))
       (log (concatenate 'string root "/action.log")))
  (ensure-directories-exist output)
  (with-open-file (in input)
    (with-open-file (out output :direction :output :if-exists :supersede)
      (loop for line = (read-line in nil)
            while line
            do (write-line line out))))
  (with-open-file (stream log :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (write-string "a" stream)))
EOF
printf 'A1\n' >"$PROJECT/a.in"
printf 'B1\n' >"$PROJECT/b.in"

write_program() {
  cat >"$TMP/build.pp" <<EOF
\$glob("$PROJECT")
let result = perform run(
  "$SBCL_PATH", "--script", "$PROJECT/build.lisp", "$PROJECT"
)
if result["exit"] = 0 {
  {
    :tree -> {
      "a.out" -> {
        :kind -> :file,
        :mode -> 420,
        :blob -> blob(\$file("$PROJECT/_build/default/a.out"))
      }
    }
  }
} else {
  error(string-append(result["err"], result["out"]))
}
EOF
}
write_program

build() {
  "$PP" --grant process --grant "fs:$PROJECT:ro" \
    --grant "fs:$SBCL_PATH:ro" --grant "fs:$DEST:wo" \
    --reconcile "$DEST" "$TMP/build.pp" \
    >"$TMP/out" 2>&1
}

build
if [ "$(cat "$DEST/a.out")" = "A1" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq 1 ]; then
  ok "sbcl-working-cold"
else
  bad "sbcl-working-cold" "$(cat "$TMP/out")"
fi

build
if [ "$(cat "$DEST/a.out")" = "A1" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq 2 ]; then
  ok "sbcl-working-repeat"
else
  bad "sbcl-working-repeat" "$(cat "$TMP/out")"
fi

printf 'B2\n' >"$PROJECT/b.in"
build
if [ "$(cat "$DEST/a.out")" = "A1" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq 3 ]; then
  ok "sbcl-unwanted-input"
else
  bad "sbcl-unwanted-input" "$(cat "$TMP/out")"
fi

printf 'A2\n' >"$PROJECT/a.in"
build
if [ "$(cat "$DEST/a.out")" = "A2" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq 4 ]; then
  ok "sbcl-input-rebuild"
else
  bad "sbcl-input-rebuild" "$(cat "$TMP/out")"
fi

rm -rf "$DEST"
mkdir "$DEST"
build
if [ "$(cat "$DEST/a.out")" = "A2" ] \
    && [ "$(wc -c <"$PROJECT/action.log")" -eq 5 ]; then
  ok "sbcl-artifact-restoration"
else
  bad "sbcl-artifact-restoration" "$(cat "$TMP/out")"
fi

cat >"$TMP/closed.pp" <<'EOF'
let request = {
  :tool -> {:tree -> {
    "bin/sbcl" -> {:kind -> :file, :mode -> 493, :blob -> blob("sbcl")}
  }},
  :tool-path -> "bin/sbcl",
  :args -> ["--script", "build.lisp"],
  :inputs -> {:tree -> {
    "build.lisp" -> {:kind -> :file, :mode -> 420, :blob -> blob("(print :ok)\n")}
  }},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> ["_build/default/a.out"]
}
print(request)
EOF
"$PP" "$TMP/closed.pp" >"$TMP/closed.out" 2>&1
if grep -q '"bin/sbcl"' "$TMP/closed.out" \
    && grep -q -- '"--script" "build.lisp"' "$TMP/closed.out" \
    && grep -q '"_build/default/a.out"' "$TMP/closed.out"; then
  ok "sbcl-closed-request"
else
  bad "sbcl-closed-request" "$(cat "$TMP/closed.out")"
fi

if [ "$fail" -eq 0 ]; then echo "=== SBCL ADAPTER TEST PASSED ==="; fi
exit "$fail"
