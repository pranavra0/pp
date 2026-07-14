#import "/lib.typ": example

= Capabilities and secrets

A pure computation needs no permission: pp will add, compare, and build lists
all day without asking. The moment a computation reaches out and touches the
world — reads a file, runs a process, makes a request — it needs a
capability: an unforgeable token that says it is allowed to. No capability,
no effect. This is not a sandboxing layer bolted on the side; it is the only
way a world-touching effect ever runs.

Here is a program that tries to read a file with no authority at all:

#example("cap-read")

The read is refused before it happens. The check is on the authority, not on
whether the file exists or what it contains — pp never looked. The error names
the effect, the missing access, and where the attempt was made.

== Capabilities enter only at the root

There is no expression that creates authority. You cannot write
`filesystem("/", :rw)` — `filesystem` is an unbound symbol, not a
constructor. The sole mint
is the command line: `--grant` hands the program a capability as it starts, and
nothing inside the language can manufacture one. Grant the read above a covering
filesystem capability and the same effect succeeds:

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

Code holds capabilities, passes them around, and attenuates them — but only
ever downward. `current-capabilities()` reifies the ambient authority as of the
call; it is an observation of the ceiling every `perform` already checks
against, not a mint. Two forms narrow it:

- `cap-restrict(cap, scope)` — restricts `cap` to a sub-scope, optionally to a
  narrower mode, for example `cap-restrict(cap, "src", :ro)`. Asking for a mode wider
  than `cap` already grants at that scope is a `Capability_error`, never a
  silent widen.
- `cap-compose(a, b, …)` — unions capabilities the code already holds; it can
  only ever produce authority already present in its arguments.

`with-caps(cap-expr) { body }` then replaces the ambient authority with
`cap-expr` for the extent of `body`. A subset check against the current ambient gates it.
So a narrowing composes even when some other binding still lexically holds a
broader value. The narrowing is restored when `body` returns, tail-calls,
or raises. There is deliberately no union-with-ambient form: the instant
capability values exist, unioning with the ambient would be a widening
backdoor.

Authority is a ceiling, re-checked at every `perform`. It is never part of a
value's identity: widening the grant does not rename or invalidate anything, and
narrowing it does not.

== Authority gates the cache, transitively

A cache hit is a message from a past run to this one, so authority has to gate
it too — not just live effects. When pp considers serving a node's stored
result, it requires the caller's capabilities to cover the transitive read
closure of that result: every cell the node read, and recursively every cell
its child nodes read. A caller scoped to `src/` is not served a hit on a node
whose closure touched `/etc/passwd`. That holds even though the expensive work
is already done and sitting in the store. Being handed the result would tell it
that the read happened and what it produced. A capability denial is not
memoized, so granting the authority later still yields the hit.

This is also why a node may not carry a capability across its own boundary in
either direction: a node whose free variable is (or contains) a capability is
rejected before it is keyed, and a node whose result is (or contains) one is
rejected before it is stored. Authority that rode a cached result out to a
narrower caller would defeat the whole check.

== Secrets: sealed cells

A secret is authority-adjacent but a different problem: you want a computation
to use a value without that value's bytes leaking into the terminal or, worse,
into the content-addressed store, where any later run could read them back. A
`secret:` grant handles this. A read covered by `secret:` — and not also by a
plain `fs:` grant over the same path — returns a sealed value instead of an
ordinary string:

#example("cap-secret", sh: true)

Three things hold at once. The sealed value prints redacted as `#<sealed>`, so
it cannot leak by being printed. Its bytes are pinned in memory only and are
never written to the store, so a scan of the whole store never finds them — the
`grep` above comes up empty even though a node ran and populated the store. And
a hash of those bytes does ride in the node's trace, so the cache stays
correct: rotate the secret and exactly the nodes that observed it are
invalidated, while their siblings keep hitting.

Deriving from a secret inside a node — the length, above — produces ordinary
data, because the derived value is no longer the secret. The one explicit way to
turn a sealed value back into a plain string is `unseal(v)`; there is no
implicit dataflow tainting. Unsealing is a deliberate, greppable boundary, so
the confidentiality of a secret ends exactly where the program says it does. If
a path is covered by both a `secret:` and an `fs:` grant, the ordinary
filesystem behaviour wins: the deployment that granted plain access is saying
"not secret here".
