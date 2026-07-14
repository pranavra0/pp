#import "/lib.typ": example

= Building with pp

A build system is a graph of tool runs with caching: compile each source to an
object, link the objects, don't redo work whose inputs haven't changed. pp
already has that graph. A `node` is a cached computation keyed by its code and
inputs; the store keeps its result. Point a node at a compiler and you have a
build system — no new machinery, just the effect that runs a process and the
primitives that move bytes into the store.

This chapter builds a real C program that way. It then shows the three things a
build system has to get right: a null rebuild does nothing, a one-line edit
recompiles only what depends on it, and deleting the outputs restores them
without re-running a single tool.

== A compilation unit is a node

Running a tool is a side effect, so it goes through `perform`, and it needs
authority — the `process` capability from the chapter on capabilities. The plain
form is `run`; the one you build with is `run-dep!`:

```
perform run-dep!("greet.d", "cc", "-MD", "-MF", "greet.d", "-O0", "-c",
  "/abs/src/greet.c", "-o", "greet.o")
```

`run-dep!` runs the command exactly like `run` — the first extra argument names a
Makefile-style depfile the tool is told to write (`cc -MD -MF greet.d`). The
command runs in the node's own sandbox directory, so relative outputs like
`greet.o` land in scratch that no other node can see. That output is not yet a
value; you pull it into the store with `blob` and `slurp`:

```
blob(slurp("greet.o"))
```

`slurp` reads the sandbox file; `blob` writes its bytes into the
content-addressed store and returns a short `"blob:<hash>"` reference. Wrap the
whole thing in a `node` and a compilation unit becomes a cached value: the same
source and the same command hash to the same node, so the object is computed
once and shared by every later run.

== Depfiles refine the trace

A node records which cells it read, and re-runs only when one of them changes.
The question is what a `cc` invocation reads. The conservative answer — the
whole source tree — would recompile everything on any edit. That is what
`run-dep!` avoids. After the command exits, pp parses the depfile the tool wrote.
It refines the node's trace to exactly the files the compiler actually
opened. `greet.c` includes `greet.h`, so `greet.o`'s node depends on those two
files and nothing else. `main.c` includes the same header, so it depends on
`main.c` and `greet.h`.

That refinement is the whole basis of incrementality below: editing `greet.c`
touches `greet.o`'s trace but not `main.o`'s, so only `greet.o` is rebuilt. A
tool that writes no depfile falls back to the coarse whole-tree dependency —
sound, just less precise. The trust is explicit and per-call: you chose
`run-dep!`.

== Blobs and materialization

A node returns a `blob:` reference, not bytes. The program's final value is a
map from output path to reference — the build tree you want on disk:

```
{"greet.o" -> "blob:…",
 "main.o"  -> "blob:…",
 "prog"    -> "blob:…:x"}
```

The trailing `:x` marks an executable. You hand that map to the reconciler with
`--reconcile <root>`. It diffs the map against what is already under `<root>`
and materializes the difference from the store, writing a file only when its
hash differs from the one on disk. The reconciler and its diff-and-converge loop
are the subject of a later chapter; here it is just the step that turns the
build tree into files. Because outputs are addressed by content, materializing
them never re-runs a tool: the bytes are already in the store.

== The incremental story

Here is the whole build as one shell transcript. The program compiles two
translation units and links them; the grants give it read access to the
sources, write access to the build directory, and process authority. Rather than
show timings, which aren't reproducible, it counts external processes straight
from the store's journal — the same journal that makes "zero processes" a fact
you can check rather than a claim.

#example("build-incremental", sh: true)

Read the four sections in order. The cold build runs three processes — two
compiles and one link — and materializes three files. The second build changes
nothing: every node is a store hit, so zero processes run and the reconciler
writes nothing (`create=0 update=0 delete=0`). This is the null rebuild, and it
does no work because there is no work whose inputs changed.

Editing `src/greet.c` changes one file. Its depfile refined `greet.o`'s trace to
`greet.c` and `greet.h`, so `greet.o` rebuilds; `main.o`'s trace didn't include
`greet.c`, so it is served from the store untouched. The transcript confirms it:
`recompiled: greet.c`, two new processes (the one compile plus the relink). This
is the property that makes an incremental build worth having — work is
proportional to what changed, not to the size of the project.

Finally, `rm -rf build` deletes every output. The rebuild runs zero processes:
the reconciler finds an empty tree, diffs it against the same build map, and
materializes all three files straight from the store. The restored binary is
byte-identical to the one deleted. Outputs are a cache of the store, and the
store is the source of truth — so losing them costs a copy, never a compile.
