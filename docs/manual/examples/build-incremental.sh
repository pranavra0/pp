#!/bin/sh
# Building a tiny C program with pp, then the incremental story. A throwaway
# store (temp HOME) keeps this hermetic; output is counts, never timings, so
# it is byte-reproducible.
export HOME=$(mktemp -d)
cd "$HOME"
mkdir -p src build

# --- a two-file C program: main() calls greet() ---
cat > src/greet.h <<'EOF'
void greet(void);
EOF
cat > src/greet.c <<'EOF'
#include "greet.h"
#include <stdio.h>
void greet(void) { printf("hello from pp\n"); }
EOF
cat > src/main.c <<'EOF'
#include "greet.h"
int main(void) { greet(); return 0; }
EOF

# --- the build: one node per translation unit, then a link node ---
# compile: run-dep records the EXACT files cc read (the .d depfile), then blob
# ingests the .o into the store. link: write each object into the node's
# sandbox, link them, blob the result. The program's value is the desired
# build tree: {relpath -> blob-ref}, ":x" marking the executable.
cat > build.pp <<EOF
def each(f, lst) { if nil?(lst) { nil } else { f(car(lst)); each(f, cdr(lst)) } }
def foldl2(f, acc, lst) { if nil?(lst) { acc } else { foldl2(f, f(acc, car(lst)), cdr(lst)) } }
def zip2(a, b) {
  if nil?(a) { nil } else { cons(cons(car(a), car(b)), zip2(cdr(a), cdr(b))) }
}
def compile(name) {
  node {
    perform run-dep(string-append(name, ".d"), "cc", "-MD", "-MF", string-append(name, ".d"), "-O0", "-c", string-append("$HOME/src/", name, ".c"), "-o", string-append(name, ".o"))
    blob(slurp(string-append(name, ".o")))
  }
}

def link(objs) {
  force(node { each(
fn(o) { perform write-file(string-append(car(o), ".o"), blob-get(cdr(o))) }, objs)
    do {
      perform write-file("link.d", "prog: ")
      do {
        perform run-dep("link.d", "sh", "-c", "cc -o prog greet.o main.o")
        blob(slurp("prog")) } } }) }
let (names = list("greet", "main"), objs = zip2(names, force-deep(map(compile, names))), prog = link(objs)) {
  foldl2(

fn(m, o) { map-insert(m, string-append(car(o), ".o"), cdr(o)) }, map-insert({}, "prog", string-append(prog, ":x")), objs)
}
EOF

G="--grant fs:$HOME/src:ro --grant fs:$HOME/build:wo --grant process"
J="$HOME/.pp/store/journal/log"
execs() { n=$(grep -c '^exec ' "$J" 2>/dev/null); echo "${n:-0}"; }
fs() { grep -oE 'create=[0-9]+ update=[0-9]+ delete=[0-9]+' "$HOME/out"; }
build() { "$PP" $G --reconcile "$HOME/build" build.pp > "$HOME/out" 2>&1; }

# The command a reader runs (grants shown Zig-style; paths shortened):
echo '$ pp --grant fs:src:ro --grant fs:build:wo --grant process \'
echo '     --reconcile build build.pp'

echo
echo '-- cold build'
build
echo "processes: $(execs)"
echo "fs: $(fs)"
echo "prog says: $(./build/prog)"
cp build/prog prog.cold

echo
echo '-- build again, nothing changed'
before=$(execs); build
echo "new processes: $(( $(execs) - before ))"
echo "fs: $(fs)"

echo
echo '-- edit src/greet.c, rebuild'
cat > src/greet.c <<'EOF'
#include "greet.h"
#include <stdio.h>
void greet(void) { printf("hello again from pp\n"); }
EOF
before=$(execs); n0=$(wc -l < "$J")
build
# which .c files were compiled in the new journal entries:
echo "recompiled: $(tail -n +"$((n0 + 1))" "$J" | grep -oE '[a-z]+\.c' | sort -u | tr '\n' ' ' | sed 's/ $//')"
echo "new processes: $(( $(execs) - before ))"
echo "fs: $(fs)"
echo "prog says: $(./build/prog)"
cp build/prog prog.edited

echo
echo '-- rm -rf build, rebuild'
rm -rf build
before=$(execs); build
echo "new processes: $(( $(execs) - before ))"
echo "fs: $(fs)"
if cmp -s build/prog prog.edited; then echo "restored byte-identical: yes"
else echo "restored byte-identical: no"; fi
echo "prog says: $(./build/prog)"

rm -rf "$HOME"
