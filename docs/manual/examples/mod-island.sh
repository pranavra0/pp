#!/bin/sh
# An island is a module referenced by URI and pinned INLINE by the content
# hash of its source tree. Resolution never touches the network: the pin names
# an immutable tree in the island cache. An unpinned form is a hard error that
# names the fix; `pp --update` derives the pin and writes it into the source;
# the pinned form then evaluates the tree's entry.pp as a module. Hermetic
# throwaway HOME (which also holds the island cache).
export HOME=$(mktemp -d)
mkdir -p "$HOME/lib"
printf 'def greet(who) { string-append("hello, ", who) }\n' > "$HOME/lib/entry.pp"
cd "$HOME"

cat > app.pp <<'PP'
let (m = island("file:./lib")) {
  import(m)
  print(greet("world"))
}
PP

echo '$ pp island-pins app.pp   # the form is unpinned'
"$PP" island-pins app.pp 2>&1

echo
echo '$ pp --update app.pp      # derive the pin and write it into the source'
"$PP" --update app.pp 1>/dev/null

echo
echo '$ cat app.pp              # the pin is now part of the code'
cat app.pp

echo
echo '$ pp app.pp               # resolve the pinned tree and run it'
"$PP" app.pp 2>&1

rm -rf "$HOME"
