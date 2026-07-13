#import "/lib.typ": example

= Nodes and content-addressing

The previous chapter ended on `delay` and `force`: a thunk runs at most once,
and two identical thunks in one run are the same thunk. `node` extends that idea
past the edge of a single run. You wrap a computation in `node`. Its result is
content-addressed and written to a store on disk (`~/.pp/store`). The next
computation that asks for the same thing finds the answer already there, instead
of recomputing it. That next computation might come later in this run, in a
separate process, or on another machine sharing the store.

== The node key

What makes two computations "the same thing" is a hash. A node's key is

#block(inset: (left: 1em), `H(code ‖ free-var value-hashes)`)

— the hash of the node's code together with the values of the free variables
that code references (this is LAW 20). Nothing else is in the key: not the
ambient capabilities, not the config, not the handler stack, not the rest of the
environment. Identical code fed identical inputs produces an identical key, and
the same key is the same node.

Write the same node twice and pp treats them as one. The first force runs the
body and stores the result. The second finds that result by key. A store hit
does not replay whatever the body printed, so the side effect happens exactly
once:

#example("node-identity")

The key folds in the values of free variables, not the code that computed
them. `x` and `y` below are built differently but are the same value. So the two
nodes keyed on them are the same node, and the body runs once. A different input
means a different key, and runs:

#example("node-freevars")

This is why the key excludes the whole environment. Rebind an unrelated global
and every node keyed on it is untouched. Change a value a node actually reads,
and that node, and only that node, re-keys.

== Caching across runs

Because the store is on disk, node results outlive the process that produced
them. A `delay` memoizes within one run; a `node` memoizes across runs. Run a
program, exit, then run it again. The second process serves the first's results
without repeating the work:

#example("node-reuse", sh: true)

The body prints on the first run and is silent on the second. The second process
never entered the body. This is the same collapse `force` gives you in memory,
made durable: equal computations run once, no matter how many processes ask.

== Pure compute needs no capability

None of these examples were granted anything. `node-identity` and
`node-freevars` run with a bare `pp file.pp`, no `--grant`, because arithmetic
touches nothing outside itself. Capabilities govern authority over the world,
and the chapter on capabilities covers them. A computation that only computes
needs none, and caching it needs none either. The moment a node reads the
world — a file, the environment, a subprocess — the cache has to account for
what it saw. That accounting is the subject of the next chapter.
