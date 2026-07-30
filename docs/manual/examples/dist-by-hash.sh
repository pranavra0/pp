#!/bin/sh
# Distribution in pp is not a language feature: identity is a content hash, so
# a computation has the SAME name on every machine, and a result is moved by
# that hash. Two throwaway HOMEs stand in for two machines (each has its own
# ~/.pp store); a shared directory is the transport (a plain local-dir
# loopback — no network transport ships yet (see docs/THREAT-MODEL-cluster.md).
# Content hashes are deterministic, so they are reproducible output.
export HOME=$(mktemp -d)
A="$HOME/machine-a"; B="$HOME/machine-b"; SHARED="$HOME/shared"
mkdir -p "$A" "$B" "$SHARED"

cat > "$HOME/node.pp" <<'PP'
print(force(node {
  log!("building greeter.o")
  6 * 7
}))
PP

echo '$ pp node.pp                 # on machine A: the node body runs'
HOME="$A" "$PP" "$HOME/node.pp" 2>&1
KEY=$(ls "$A/.pp/store/traces")
RH=$(grep -oE '"[0-9a-f]{64,}"' "$A/.pp/store/traces/$KEY" | head -1 | tr -d '"')
echo "node key:    $KEY"
echo "result hash: $RH"

echo
echo '$ pp node.pp                 # on machine B, independently: SAME node key'
HOME="$B" "$PP" "$HOME/node.pp" 2>&1
KEY_B=$(ls "$B/.pp/store/traces")
[ "$KEY_B" = "$KEY" ] && echo "machine B computed the same key: yes"

echo
echo '# A publishes the result object by hash; B pulls it by that hash.'
echo '$ pp --transport-push object <hash> shared    # on A'
HOME="$A" "$PP" --transport-push object "$RH" "$SHARED" >/dev/null 2>&1
echo '$ pp --transport-pull object <hash> shared    # on B, re-hash-verified'
HOME="$B" "$PP" --transport-pull object "$RH" "$SHARED" 2>&1
diff -q "$A/.pp/store/objects/$RH" "$B/.pp/store/objects/$RH" >/dev/null \
  && echo "byte-identical across the transport: yes"

echo
echo '# A tampered object is refused on receipt: the hash IS the integrity check.'
printf 'X' | dd of="$SHARED/objects/$RH" bs=1 seek=3 count=1 conv=notrunc 2>/dev/null
echo '$ pp --transport-pull object <hash> shared    # after a byte flips in transit'
HOME="$B" "$PP" --transport-pull object "$RH" "$SHARED" 2>&1

rm -rf "$HOME"
