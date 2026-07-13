#import "/lib.typ": example

= The store and verifying traces

A node's key decides identity: which computation this is. It does not decide
whether a cached result is still good. That is a separate question, and pp
answers it in a way that never trusts a clock.

== The store

Everything a node produces lives under `~/.pp/store`, in three
content-addressed parts:

#example("store-layout", sh: true)

- `objects/` — result values, each file named by the hash of the value it
  holds.
- `traces/` — one file per node key, holding the set of traces recorded for
  that node (see below).
- `blobs/` — raw bytes ingested by `(blob ...)`, named by their hash. The
  program above turned a file's contents into a `blob:` reference, and the bytes
  landed here.

(`VERSION` stamps the store format and `locks/` guards concurrent writers.
Neither is content you address directly.)

== A hit is a verified trace, not a timestamp

When a node runs, pp records every observation it makes of the world as a
`(cell, hash)` pair: each file it reads, each config value, each subprocess
tool. That record is a verifying trace: not "this ran at 3pm" but "this is what
the node saw."

On the next force, pp does not check a modification time. It re-observes every
cell in the trace, and serves the stored result only if every observed hash still
matches. A changed input fails the match and forces a recompute. An unchanged
input matches and hits. One key holds a set of traces. So a node that ran
under two different toolchains or platforms keeps a valid trace for each, and
reverting a file re-matches its older trace. A cache hit is therefore always
re-checked against the current world. It can never serve stale data, because
"stale" means "some observed cell no longer matches", and that is exactly
what the hit test checks.

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

The node key (`f1b010a0e48c` here) is stable: it is a hash of the code, which
did not change. What changed is the world the trace was verified against. The
first run has nothing to verify against and misses. The second re-observes the
one file cell, finds it unchanged, and hits. Editing the file makes that cell's
hash no longer match. The stored trace goes stale, no other trace in the set is
usable, and the node recomputes.

== Auditing the cache

Two flags let you check the cache instead of trusting it.

`--no-cache` skips cache reads, so every node recomputes, while still writing
fresh results and traces. Use it to force a clean build. A node that would
otherwise hit reports its miss as `cache reads disabled (--no-cache)`.

`--check` re-runs each missed node's body and compares the new result hash
against the stored one. Matching hashes confirm the node is deterministic. A
divergence flags the node as volatile and fails the run. This is how you catch a
computation that claims to be a pure function of its inputs but is not, the one
thing content-addressed caching cannot tolerate.
