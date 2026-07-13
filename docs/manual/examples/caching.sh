#!/bin/sh
# A node's result is cached in the content-addressed store and reused by a
# LATER process. We use a throwaway store (a temp HOME) so this is hermetic.
export HOME=$(mktemp -d)

cat > prog.pp <<'PP'
(def (expensive)
  (node (do (print "compiling greeter.o") (* 6 7))))
(print (expensive))
PP

echo '$ pp prog.pp     # first run: the node body executes'
"$PP" prog.pp

echo
echo '$ pp prog.pp     # second run: the result is served from the store'
"$PP" prog.pp

rm -rf "$HOME"
