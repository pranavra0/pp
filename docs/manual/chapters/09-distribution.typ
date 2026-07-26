#import "/lib.typ": example

= Distribution

Here is the thesis this whole manual has been building toward: there is no
local/remote distinction at the language surface. There is no `remote-eval`, no
placement annotation, no node-pinning form, and there never will be. `force` is
the only execution primitive. Where a force runs is a scheduler decision, chosen
with a flag, never written into the program. A program is byte-identical whether
it runs on one core, eight, or a cluster. Microservices exist because no
mainstream language lets you say "evaluate this elsewhere and flow the result
back". The moment location becomes syntax, every caller hard-codes topology, and
you have rebuilt the deployment boundary inside the language.

`--schedule serial | parallel:N | race:N | remote:<member>` selects the policy.
`parallel:N` forks workers across cores. `race:N` runs N redundant copies and
takes the first. `remote:<member>` ships the work to another machine. These are
the same feature at different fan-out. "Run on N machines and take the first" is
a handler swap, not an infrastructure project. The scheduler is
result-transparent: it changes only where and when work runs, never the answer.
So it appears in no cache key and no trace. `pp --check` proves this. It re-runs
any non-serial policy forced serial against the same store and fails on any hash
mismatch.

== Identity is location-independent

Location can be a scheduler's business, not the program's, because identity is a
content hash. A node's key is a hash of its code and its inputs' values, never
of where or when it ran. Two machines that evaluate the same node therefore
compute the same key and a byte-identical result, with no coordination. A result
is then moved by that hash. It is published into a shared store and pulled by
name, then re-hashed on receipt so a corrupted or tampered artifact is refused.
The content address is the integrity check.

The transcript below uses two throwaway `HOME`s as two machines, each with its
own `~/.pp` store, and a shared directory as the transport. Machine A builds a
node. Machine B, given the same program, computes the identical node key without
ever talking to A. Then A publishes the result object by hash and B pulls it,
byte-identical. Flipping one byte in transit makes B reject it.

#example("dist-by-hash", sh: true)

The two machines never agreed on a key. They derived the same one, because the
key is a function of the code and nothing else. That is what makes a build
computed "here" usable "there". The result is addressed by what it is, not by
where it was produced.

== Transport boundary

The by-hash sync, re-hash-on-receipt, signed-token authority checks, and remote
placement are implemented and tested over a local-directory transport. Two
separate `~/.pp` stores stand in for two machines. No SSH implementation or
generic transport plugin ships today. A remote provider can carry the same
canonical artifacts and signed requests; integrity and authority remain runtime
checks rather than promises made by the connection.

== Host-qualified identity

A running process is not a pure value. Here the "same identity everywhere" story
inverts in exactly the right way: a process on host B is a different cell than
the same process on host A. Host-qualified identity names world state, "the
greeter running on B", not a location you dispatch to. The desired-state map
from the previous chapter generalizes one level for this, from
`{domain → desired}` to `{host → {domain → desired}}`. `--member-name B` selects
host B's slice and hands it to the unchanged reconciler. A member is then just
`pp --watch --supervise --member-name B` on its own slice: the single-machine
supervisor, verbatim, fed a slice of a cluster-wide value. Naming a host absent
from the map is a hard error, not a silent no-op.

Membership is ambient configuration: which machines exist, and where their
stores are. It is read from `~/.pp/cluster/members` or `$PP_CLUSTER_MEMBERS`. It
is deliberately not a capability. An address is not an authority ceiling, the
same distinction the language draws everywhere between location and permission.
Authority to act across the cluster travels separately, as a signed token minted
from the same `--grant` grammar you use locally.

== Trace merge, audit, and growth

Because a result carries its verifying trace, syncing a result syncs its
evidence. A machine that pulls a node's result also pulls the `(cell, hash)`
observations that justify it. It re-verifies them against its own world before
serving a hit. The authority checks survive the crossing. A hit served across
the wire is gated on the requesting token's authority over the trace's read
closure, exactly as a local hit is gated on the caller's. A narrow caller cannot
launder a broad read through a cached aggregator just because the bytes arrived
over a network. And `pp why`, run on a machine that pulled a trace, redacts any
cell the local caller is not authorized to see, identically to a purely local
run. Audit redacts. It never lies.

A shared store only grows, so growth is bounded explicitly. Each successful
pass records its desired object and forced node keys as a wanted root. `pp gc`
walks the same durable child, result, and tree-blob edges used by validation and
stabilization, then sweeps only unreachable objects, traces, and blobs. It is
never automatic. A grace period protects concurrent writes, and a changed root
manifest stops deletion.
