#!/bin/sh
# `pp --diff` runs a program under BOTH back ends and compares the values
# every top-level form returned. It exits 0 when they agree, 1 (naming the
# file and both value lists) when they diverge. The program's own output
# therefore appears twice — once per engine — and the exit code is the verdict.
export HOME=$(mktemp -d)

cat > "$HOME/prog.pp" <<'PP'
;; a tail-recursive sum — both back ends must run it in constant stack
;; and return the same value
(def (sum-to n acc)
  (if (= n 0) acc (sum-to (- n 1) (+ acc n))))
(print (sum-to 100000 0))
PP

echo '$ pp --diff prog.pp'
"$PP" --diff "$HOME/prog.pp"
echo "exit: $?"

rm -rf "$HOME"
