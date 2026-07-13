#!/bin/sh
# The same read-file effect that fails without authority succeeds once the
# root grants a covering capability. Capabilities enter ONLY here, on the
# command line: there is no expression that mints one. A throwaway HOME with
# a file under it keeps the run hermetic; we cd into it and use relative
# paths so nothing machine-specific reaches the output.
export HOME=$(mktemp -d)
mkdir -p "$HOME/etc"
printf 'db1.internal' > "$HOME/etc/hostname"
cd "$HOME"

cat > read-hostname.pp <<'PP'
print(perform read-file("etc/hostname"))
PP

echo '$ pp read-hostname.pp                       # no grant: refused'
"$PP" read-hostname.pp 2>&1

echo
echo '$ pp --grant fs:etc:ro read-hostname.pp     # covering grant: allowed'
"$PP" --grant fs:etc:ro read-hostname.pp 2>&1

rm -rf "$HOME"
