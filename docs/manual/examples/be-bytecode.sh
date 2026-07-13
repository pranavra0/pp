#!/bin/sh
# The same program under each back end. `pp` uses the tree-walker; `pp
# --bytecode` compiles to the stack machine. Their output is identical.
export HOME=$(mktemp -d)

cat > "$HOME/prog.pp" <<'PP'
def fib(n) { if n < 2 { n } else { fib(n - 1) + fib(n - 2) } }

print(fib(15))
PP

echo '$ pp prog.pp'
"$PP" "$HOME/prog.pp"

echo '$ pp --bytecode prog.pp'
"$PP" --bytecode "$HOME/prog.pp"

rm -rf "$HOME"
