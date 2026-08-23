#import "/lib.typ": example

= The store and verifying traces

A node's key decides identity: which computation this is. It does not decide
whether a cached result is still good — pp answers that in a way that never
trusts a clock.

== The store

Everything a node produces lives under `~/.pp/store`, in three
content-addressed parts:

#example("store-layout", sh: true)

- `objects/` — result values, each file named by the hash of the value it
  holds.
- `traces/` — one file per node key, holding the set of traces recorded for
  that node (see below).
- `blobs/` — raw bytes ingested by `blob(…)`, named by their hash. The
  program above turned a file's contents into a blob identity, and the bytes
  landed here.

(`VERSION` stamps the store format and `locks/` guards concurrent writers.
Neither is content you address directly.)

== A hit is a verified trace, not a timestamp

When a node runs, pp records every observation of the world as a `(cell,
hash)` pair: each file, config value, subprocess tool. That record is a
verifying trace: not "this ran at 3pm" but "this is what the node saw."

On the next force pp re-observes every cell in the trace and serves the stored
result only if every hash still matches; no modification times. One key holds
a set of traces, so a node that ran under two toolchains keeps a valid trace
for each, and reverting a file re-matches the older trace. A hit is always
re-checked against the current world: "stale" means "some observed cell no
longer matches", exactly what the hit test checks.

pp checks authority at the same moment. It serves a stored result only if the
caller holds capabilities covering every file cell in the trace's read closure
(LAW 23b). Reads propagate to enclosing nodes, so the check is transitive: a
narrow caller cannot launder a broad read through a cached aggregator. A
capability denial is never cached. Authority gates access to a result, it does
not rename it.

== pp why

`pp why file.pp` runs the program and reports, to stderr, the fate of every
node force: a first-build miss, a verified hit, or a stale trace naming the cell
that changed. Here a build reads a file, the same run repeated hits, then you
edit the input and the node re-runs:

#example("store-rebuild", sh: true)

The node key (`f1b010a0e48c` here) is stable: it hashes the code, which did
not change. The world the trace is verified against changed. First run misses
(nothing to verify against); second re-observes the one file cell and hits;
the edit makes that cell's hash mismatch, the trace goes stale, no other trace
is usable, and the node recomputes.

== Auditing the cache

Two flags let you check the cache instead of trusting it.

`--no-cache` skips cache reads — every node recomputes, fresh results and
traces are still written. A would-be hit reports `cache reads disabled (--no-cache)`.

`--check` re-runs each missed node's body and compares result hashes. Matching
hashes confirm determinism; divergence flags the node volatile and fails the
run. This catches a computation that claims to be a pure function of its
inputs but is not — the one thing content-addressed caching cannot tolerate.
