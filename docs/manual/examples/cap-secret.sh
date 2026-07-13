#!/bin/sh
# A secret is granted with `secret:` instead of `fs:`. A read covered by a
# secret grant (and NOT by a plain fs grant) yields a SEALED value: it prints
# redacted, its bytes are pinned in memory only and never written to the
# content-addressed store, yet a hash of those bytes still rides in the node's
# trace — so rotating the secret invalidates exactly its observers. Hermetic:
# throwaway HOME, a secret file under it, relative paths.
export HOME=$(mktemp -d)
mkdir -p "$HOME/vault"
printf 'hunter2-swordfish' > "$HOME/vault/token"
cd "$HOME"

# (1) A sealed value prints redacted — the bytes never reach the terminal.
cat > show.pp <<'PP'
print(slurp("vault/token"))
PP
echo '$ pp --grant secret:vault show.pp'
"$PP" --grant secret:vault show.pp 2>&1

# (2) Derive from the secret inside a node (its length), which populates the
#     store, then scan the whole store for the plaintext.
echo
cat > derive.pp <<'PP'
print(force(node { string-length(unseal(slurp("vault/token"))) }))
PP
echo '$ pp --grant secret:vault derive.pp     # length of the secret'
"$PP" --grant secret:vault derive.pp 2>&1

echo
echo '$ grep -r hunter2-swordfish ~/.pp/store  # the bytes are not there'
if grep -rq 'hunter2-swordfish' "$HOME/.pp/store" 2>/dev/null; then
  echo 'FOUND (leak)'
else
  echo '(no match — secret bytes absent from the store)'
fi

rm -rf "$HOME"
