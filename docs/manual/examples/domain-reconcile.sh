#!/bin/sh
# A domain converges the world to a DESIRED state you return as a value. The
# fs domain (stdlib/domain-fs.pp) takes a {relative-path -> content} map and
# makes a directory tree match it: creating, updating, and deleting files.
# Hermetic: a throwaway HOME (so the store and journal are fresh) and a root
# under it. The reconcile summary's absolute root path is filtered to ROOT.
export HOME=$(mktemp -d)
ROOT="$HOME/site"

cat > "$HOME/site.pp" <<'PP'
{"index.html" "<h1>pp</h1>\n"
 "conf/app.txt" "mode=prod\n"}
PP

filter() { sed "s#root=[^ ]*#root=ROOT#"; }

echo '$ pp --grant fs:ROOT:rw --reconcile ROOT site.pp   # first pass: create'
"$PP" --grant "fs:$ROOT:rw" --reconcile "$ROOT" "$HOME/site.pp" 2>&1 | filter
( cd "$ROOT" && find . -type f | sort )
echo "conf/app.txt: $(cat "$ROOT/conf/app.txt")"

echo
echo '# Introduce drift: delete one file, corrupt another.'
rm "$ROOT/index.html"
echo 'mode=DEV' > "$ROOT/conf/app.txt"

echo '$ pp --grant fs:ROOT:rw --reconcile ROOT site.pp   # second pass: restore'
"$PP" --grant "fs:$ROOT:rw" --reconcile "$ROOT" "$HOME/site.pp" 2>&1 | filter
( cd "$ROOT" && find . -type f | sort )
echo "conf/app.txt: $(cat "$ROOT/conf/app.txt")"

rm -rf "$HOME"
