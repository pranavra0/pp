#import "/lib.typ": example

= Nodes and content-addressing

The previous chapter ended on `delay` and `force`: a thunk runs at most once,
and identical thunks in one run are the same thunk. `node` extends that past
the edge of a single run: wrap a computation in `node` and its result is
content-addressed into a store on disk (`~/.pp/store`). The next computation
asking for the same thing — later in this run, in another process, or on
another machine sharing the store — finds the answer already there.

== The node key

What makes two computations "the same thing" is a hash. A node's key is

#block(inset: (left: 1em), `H(code ‖ free-var value-hashes)`)

— the hash of the node's code plus the values of the free variables it
references (LAW 20). Nothing else: no ambient capabilities, config, handler
stack, or rest of the environment. Identical code fed identical inputs gives
an identical key; same key, same node.

Write the same node twice and pp treats them as one. The first force runs the
body and stores the result. The second finds that result by key. A store hit
does not replay whatever the body printed, so the side effect happens exactly
once:

#example("node-identity")

The key folds in free-variable values, not how they were computed. `x` and
`y` below are built differently but are the same value, so the two nodes are
one node and the body runs once. A different input means a different key,
and a run:

#example("node-freevars")

Hence excluding the whole environment: rebind an unrelated global and nodes
keyed on it are untouched; change a value a node actually reads and only that
node re-keys.

== Caching across runs

The store is on disk, so node results outlive the process. A `delay` memoizes
within one run; a `node` memoizes across runs:

#example("node-reuse", sh: true)

The body prints on the first run, is silent on the second; the second process
never entered the body. The `force` collapse made durable: equal computations
run once, however many processes ask.

== Pure compute needs no capability

None of these examples were granted anything — `node-identity` and
`node-freevars` run with bare `pp file.pp`, since arithmetic touches nothing.
A computation that only computes needs no capability; caching it needs none.
The moment a node reads the world, the cache must account for what it saw:
files, config, handlers, probes, and child results become trace cells;
ambient subprocesses are rejected. Traces and foreign execution follow.
