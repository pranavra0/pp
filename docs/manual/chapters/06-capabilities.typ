#import "/lib.typ": example

= Capabilities and secrets

A pure computation needs no permission. The moment one touches the world —
reads a file, runs a process, makes a request — it needs a capability: an
unforgeable token saying it is allowed to. No capability, no effect. Not a
sandboxing layer bolted on the side; the only way a world-touching effect ever
runs.

Here is a program that tries to read a file with no authority at all:

#example("cap-read")

The read is refused before it happens; the check is on authority, not on the
file's existence or contents — pp never looked. The error names the effect,
the missing access, and where the attempt was made.

== Capabilities enter only at the root

No expression creates authority. `filesystem` in `filesystem("/", :rw)` is an
unbound symbol, not a constructor. The sole mint is the command line:
`--grant` hands the program a capability as it starts. Grant the read above a
covering filesystem capability and it succeeds:

#example("cap-grant", sh: true)

A grant is a scheme, a target, and — for the filesystem — a mode:

- `--grant fs:<path>:ro` (or `:rw`, `:wo`) — read, write, or read-write access
  to a directory and everything under it. Scope matching is by path component
  on the canonicalized full path, so `fs:/tmp:ro` covers `/tmp/x` but never
  `/tmpevil`.
- `--grant net:<host>` or `net:<host>:<port>` — network access to a host, and
  optionally one port; `net:*` wildcards the host.
- `--grant secret:<path>` — a sealed read of the files under a path (below).
- `--grant process` — the authority to run subprocesses.

Pass `--grant` more than once to hold several capabilities at once.

== User code narrows, never widens

Code holds, passes, and attenuates capabilities — only downward.
`current-capabilities()` reifies the ambient authority as of the call: an
observation of the ceiling every `perform` checks against, not a mint. Two
forms narrow it:

- `cap-restrict(cap, scope)` — restricts `cap` to a sub-scope, optionally to a
  narrower mode, for example `cap-restrict(cap, "src", :ro)`. Asking for a mode wider
  than `cap` already grants at that scope is a `Capability_error`, never a
  silent widen.
- `cap-compose(a, b, …)` — unions capabilities the code already holds; it can
  only ever produce authority already present in its arguments.

`with-caps(cap-expr) { body }` replaces ambient authority with `cap-expr` for
the extent of `body`, gated by a subset check against the current ambient —
so narrowing composes even when another binding lexically holds something
broader. Restored on return, tail call, or raise. No union-with-ambient form
exists: with capability values in the language, that would be a widening
backdoor.

Authority is a ceiling, re-checked at every `perform`, never part of identity:
widening or narrowing the grant renames and invalidates nothing.

== Authority gates the cache, transitively

A cache hit is a message from a past run, so authority gates it too. To serve
a stored result pp requires the caller's capabilities to cover its transitive
read closure: every cell the node read, recursively including child nodes. A
caller scoped to `src/` gets no hit on a node whose closure touched
`/etc/passwd` — even though the work is done and sitting in the store, being
handed the result would reveal the read. Denials are not memoized; granting
later still yields the hit.

A node may not carry a capability across its boundary either direction: one as
(or inside) a free variable is rejected before keying; one in the result,
before storing. Otherwise authority could ride a cached result out to a
narrower caller.

== Secrets: sealed cells

A secret needs the opposite guarantee: use a value without its bytes leaking
into the terminal or into the store, where any later run could read them back.
A read covered by `secret:` — not also by plain `fs:` over the same path —
returns a sealed value:

#example("cap-secret", sh: true)

Three things hold at once: the sealed value prints redacted as `#<sealed>`;
its bytes pin in memory only and never reach the store (the `grep` above comes
up empty); and a hash of the bytes rides in the trace, so rotating the secret
invalidates exactly the nodes that observed it while siblings keep hitting.

Deriving from a secret inside a node produces ordinary data — the derived
value is no longer the secret. `unseal(v)` is the one explicit way back to a
plain string; there is no implicit dataflow tainting, so confidentiality ends
exactly where the program says. If a path is covered by both `secret:` and
`fs:` grants, filesystem behaviour wins: granting plain access says "not
secret here".
