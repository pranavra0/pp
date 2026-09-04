#!/usr/bin/env bash
# pins: LAW-39
# Secret-origin values must never cross the language blob boundary. Ordinary
# malformed filesystem bytes use a separate opaque value and remain explicitly
# publishable as raw blobs.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

assert_present() {
  local name="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then ok "$name"
  else bad "$name" "missing '$pattern' in $file" "$(cat "$file" 2>/dev/null)"; fi
}
assert_absent() {
  local name="$1" pattern="$2" file="$3"
  if grep -qE "$pattern" "$file" 2>/dev/null; then bad "$name" "found '$pattern' in $file" "$(cat "$file" 2>/dev/null)"
  else ok "$name"; fi
}
assert_failed() {
  local name="$1" code="$2"
  if [ "$code" -ne 0 ]; then ok "$name"
  else bad "$name" "expected a nonzero exit"; fi
}

mkdir -p "$TMP/secret" "$TMP/ordinary"
printf 'BLOB-SECRET-SENTINEL\n' > "$TMP/secret/data"
printf '\377\000\200A' > "$TMP/ordinary/binary"
SECRET="$TMP/secret/data"
BINARY="$TMP/ordinary/binary"

# A secret-only read is sealed and must fail before blob publication.
cat > "$TMP/direct.pp" <<EOF
blob(slurp("$SECRET"))
EOF
set +e
"$PP" --grant "secret:$TMP/secret" "$TMP/direct.pp" > "$TMP/direct.out" 2>&1
code=$?
set -e
assert_failed "sealed-blob-rejected" "$code"
assert_present "sealed-blob-diagnostic" "blob cannot publish a sealed value" "$TMP/direct.out"
assert_absent "sealed-blob-no-store-leak" "BLOB-SECRET-SENTINEL" "$TMP/.pp/store"

# Nested sealed data must not be copied by --publish-object before validation.
cat > "$TMP/nested.pp" <<EOF
{:ordinary -> blob("ordinary-publication"), :secret -> slurp("$SECRET")}
EOF
set +e
"$PP" --grant "secret:$TMP/secret" --publish-object "$TMP/published" "$TMP/nested.pp" > "$TMP/nested.out" 2>&1
code=$?
set -e
assert_failed "nested-publication-rejected" "$code"
assert_absent "nested-publication-no-destination-leak" "BLOB-SECRET-SENTINEL" "$TMP/published"
assert_absent "nested-publication-no-secret-store-leak" "BLOB-SECRET-SENTINEL" "$TMP/.pp/store"

# Unsafe process specs must fail before provider execution or journaling.
mkdir -p "$TMP/proc"
cat > "$TMP/proc/run.sh" <<EOF
#!/usr/bin/env bash
printf 'PROCESS-SHOULD-NOT-RUN\n' > "$TMP/process-ran"
EOF
chmod +x "$TMP/proc/run.sh"
cat > "$TMP/process-unsafe.pp" <<EOF
perform proc-spawn({:cmd -> "$TMP/proc/run.sh", :extra -> slurp("$SECRET")})
EOF
set +e
"$PP" --grant process --grant "secret:$TMP/secret" "$TMP/process-unsafe.pp" > "$TMP/process.out" 2>&1
code=$?
set -e
assert_failed "unsafe-process-rejected" "$code"
assert_present "unsafe-process-diagnostic" "process specification is not durable" "$TMP/process.out"
assert_absent "unsafe-process-not-started" "PROCESS-SHOULD-NOT-RUN" "$TMP/process-ran"


# A missing node-scratch path must not downgrade a relative secret read.
mkdir -p "$TMP/relative-secret"
printf 'RELATIVE-SECRET-SENTINEL\n' > "$TMP/relative-secret/data"
cat > "$TMP/relative-secret.pp" <<EOF
print(force(node { slurp("relative-secret/data"); "done" }))
EOF
(cd "$TMP" && "$PP" --grant "secret:$TMP/relative-secret" \
  "$TMP/relative-secret.pp" > "$TMP/relative-secret.out" 2>&1)
assert_absent "relative-secret-no-store-leak" "RELATIVE-SECRET-SENTINEL" "$TMP/.pp/store"
# Ordinary malformed bytes are opaque, not sealed, and round-trip through blob.
cat > "$TMP/opaque.pp" <<EOF
let h = blob(slurp("$BINARY"))
do { print(h); print(blob(blob-get(h))); print(blob-get(h)) }
EOF
"$PP" --grant "fs:$TMP/ordinary:ro" "$TMP/opaque.pp" > "$TMP/opaque.out" 2>&1
expected=$(sha256sum "$BINARY" | cut -d ' ' -f 1)
assert_present "opaque-blob-hash" "$expected" "$TMP/opaque.out"
if [ "$(grep -Eo '[0-9a-f]{64}' "$TMP/opaque.out" | sort -u | wc -l | tr -d ' ')" = 1 ]; then
  ok "opaque-blob-round-trip-hash"
else
  bad "opaque-blob-round-trip-hash" "expected one stable blob hash" "$(cat "$TMP/opaque.out")"
fi
assert_present "opaque-print-redacted" "#<opaque-bytes>" "$TMP/opaque.out"
assert_absent "opaque-not-sealed" "#<sealed>" "$TMP/opaque.out"
if cmp -s "$BINARY" "$HOME/.pp/store/blobs/$expected"; then ok "opaque-bytes-identical"
else bad "opaque-bytes-identical" "stored blob differs from malformed source"; fi

# Filesystem authority takes precedence over a coincident secret grant.
cat > "$TMP/precedence.pp" <<EOF
print(blob(slurp("$BINARY")))
EOF

# Source -> opaque value -> blob artifact -> desired tree -> reconciler.
RECON="$TMP/opaque-reconcile"
cat > "$TMP/opaque-reconcile.pp" <<EOF
{:tree -> {"binary" -> {:kind -> :file, :mode -> 420, :blob -> blob(slurp("$BINARY"))}}}
EOF
"$PP" --grant "fs:$TMP/ordinary:ro" --grant "fs:$RECON:rw" \
  --reconcile "$RECON" "$TMP/opaque-reconcile.pp" > "$TMP/reconcile.out" 2>&1
assert_present "opaque-reconcile-created" "create=1" "$TMP/reconcile.out"
if cmp -s "$BINARY" "$RECON/binary"; then ok "opaque-reconcile-bytes"
else bad "opaque-reconcile-bytes" "reconciled file differs from source"; fi
"$PP" --grant "fs:$TMP/ordinary:ro" --grant "fs:$RECON:rw" \
  --reconcile "$RECON" "$TMP/opaque-reconcile.pp" > "$TMP/reconcile-again.out" 2>&1
assert_present "opaque-reconcile-healthy" "create=0" "$TMP/reconcile-again.out"
"$PP" --grant "secret:$TMP/ordinary" --grant "fs:$TMP/ordinary:ro" "$TMP/precedence.pp" > "$TMP/precedence.out" 2>&1
assert_present "filesystem-precedence-publishes" "$expected" "$TMP/precedence.out"

# Explicit unseal is the deliberate disclosure escape hatch.
cat > "$TMP/unseal.pp" <<EOF
print(blob(unseal(slurp("$SECRET"))))
EOF
"$PP" --grant "secret:$TMP/secret" "$TMP/unseal.pp" > "$TMP/unseal.out" 2>&1
secret_hash=$(sha256sum "$SECRET" | cut -d ' ' -f 1)
assert_present "explicit-unseal-publishes" "$secret_hash" "$TMP/unseal.out"
if grep -R -q 'BLOB-SECRET-SENTINEL' "$HOME/.pp/store/blobs" 2>/dev/null; then
  ok "explicit-unseal-disclosure-is-intentional"
else
  bad "explicit-unseal-disclosure-is-intentional" "explicit unseal did not publish expected bytes"
fi

if [ "$fail" -eq 0 ]; then echo "=== SEALED BLOB BOUNDARY TEST PASSED ==="; fi
exit "$fail"
