#import "/lib.typ": example

= Domains and the reconciler

A node computes a value; a build must change the world. You do not mutate it
directly — you compute a desired state: a pure, hashable value saying what the
world should contain (`{path → content}`, `{service → spec}`). A domain
observes the world, diffs against your desired value, applies the minimal
change to converge. React's contract verbatim: return the desired DOM; the
reconciler applies the diff.

Convergence follows from the value, not from a maintained script: desired
state is a pure function of input cells, so pp caches it, re-derives cheaply
on change, and re-observes reality rather than trusting a state file. Drift —
a hand-edited file, a dead service — is just a difference the next pass erases.

== A domain is observe / diff / apply

A domain is three ordinary pp functions registered over a namespace of cells:

- observe `: () → value` reads the current world. It runs fresh every pass,
  never cached.
- diff `: (observed, desired) → plan` computes what to change. It is pure: it
  runs under an empty capability set and cannot touch the world. Its result is
  cached, keyed on the diff code plus the observed and desired values.
- apply `: plan → nil` performs the plan's changes, under the domain's own
  write capability.

Core wraps every domain's apply in one discipline: a journalled intent/done
bracket, atomic writes, and verify-after-write. Core re-observes and re-diffs
once the apply returns. A plan that still has work left is a hard error. A
domain is the single writer for its namespace. So there are no write-write
races, and your code needs no ordering discipline. One rule enforces this:
stratification. The desired state may not read the domain's own cells, or
reconcile would loop forever. Reading your output tree to decide your output
tree is refused.

The trusted mechanics touching the world are a few core primitives: atomic
temp-file-plus-`rename`, `fork`/`exec`/reap, a per-domain key-value store
(`tree-observe`, `materialize-file`, `remove-file`, `proc-spawn`, …).
Everything else is pp library too: `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp` are real readable source packaging the filesystem and
process policies for explicit registration over the core-enforced protocol
(create vs update, when to restart). The built-in `--reconcile` and
`--supervise` domains implement the same policy natively in the runtime.

== Reconciling a filesystem

`pp --reconcile ROOT prog.pp` registers the built-in fs domain with a write
capability narrowed to `ROOT` and takes the program's final canonical tree
value as the desired state. File entries carry mode and blob identity;
directory entries make parents explicit. It diffs by content hash and
materializes missing and changed files atomically; files under `ROOT` that
the map does not mention are deleted. An fs write grant over `ROOT` is
required; without it nothing is written.

The transcript below reconciles two files into a fresh root, introduces drift
by hand (one delete, one edit), and reconciles again: exactly one create and
one update, tree restored. The summary names counts per kind, its root path
filtered to `ROOT` for machine-independent output.

#example("domain-reconcile", sh: true)

Nothing in `site.pp` says how to converge — no "if missing, create". It states
the desired tree; the diff does the rest. Reverting one file and restoring
another are the same mechanism.

File contents are raw blob identities, which diff without loading bytes:
`rm -rf` on the tree restores from the store with zero tool re-runs when the
desired-state nodes hit.

== Watching, and other domains

`pp --watch --reconcile ROOT prog.pp` runs, reconciles, polls observed cells,
and re-runs on change — a controller loop. Every registered domain is
re-observed and re-applied each tick, whichever cell changed; cheap when
nothing moved because the plan cache turns a no-op pass into a hit. External
deletion or drift is caught within one poll interval.

The process domain is the same protocol over a different world:
`pp --supervise prog.pp` (usually with `--watch`) takes `{service-name → spec}`
and keeps the process table matching: starts missing services, stops removed
ones, restarts changed or killed services within a poll interval. Requires
`--grant process`; refuses stratification on its own `proc:` cells like the fs
domain. A third-party domain — any observe/diff/apply triple via
`register-domain` — gets the same journal bracket, plan cache,
verify-after-write, and stratification for free. The protocol is generic, not
filesystem-shaped.

Load `stdlib/domain.pp` for composition helpers such as `domain(spec)`,
`probe(name, observe, cap)`, and `register-domains(domains)`. These are ordinary
pp functions and do not bypass the generic lifecycle.

== Fenced effects

Convergence covers only idempotent change: applying a desired state twice is the
same as applying it once. Some actions are not like that, such as sending an
email or charging a card. Those may not appear in a node at all. A node is
cache-replayable and must never carry an irreversible action. The scripting form
`fenced(KIND, SPEC)` registers such an action for the reconciler to run after
all convergent work, at most once per pass. It carries an intent/done journal.
So a crash mid-action is recovered by policy
(`--fenced-policy retry | abort | ask`) rather than by a silent retry that might
double-charge. The desired-state law tames the convergent world. Fenced effects
are the named carve-out for the part that cannot be converged.
