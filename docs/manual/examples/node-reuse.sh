#!/bin/sh
# A node's result is content-addressed in ~/.pp/store, so it survives the
# process that produced it. A second, separate run of the same program finds
# the result already there and does not re-run the body. A throwaway store (a
# temp HOME) keeps this hermetic.
export HOME=$(mktemp -d)
cd "$HOME"

cat > build.pp <<'PP'
(def (compile) (node (do (print "compiling greeter.o") (* 6 7))))
(print (compile))
PP

echo '$ pp build.pp     # first process: the node body runs'
"$PP" build.pp

echo
echo '$ pp build.pp     # second process: served from the store, body skipped'
"$PP" build.pp

rm -rf "$HOME"
