#import "/lib.typ": example

= Domains and the reconciler

A node computes a value. But a build has to change the world: write files, start
processes. pp will not let you do that by mutating it directly. Instead you
compute a desired state: a pure, hashable value that says what the world should
contain — `{path → content}`, `{service → spec}`. A domain observes the world,
diffs it against your desired value, and applies the minimal change to converge
them. This is React's contract verbatim. You never touch the DOM. You return the
desired DOM and the reconciler applies the diff. Here the world is the
filesystem and the process table.

The payoff is that convergence follows from the value, not from a script you
maintain. Your desired state is a pure function of input cells. So pp caches it,
re-derives it cheaply when an input changes, and re-observes reality rather than
trusting a state file. Drift is just a difference the next pass erases — a file
someone edited by hand, a service that died.

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

The trusted mechanics that actually touch the world are a small set of core
primitives: atomic temp-file-plus-`rename`, `fork`/`exec`/reap, a per-domain
key-value store (`tree-observe`, `materialize-file`, `remove-file`,
`proc-spawn`, and the like). Everything else is a pp library. The filesystem and
process domains ship as `stdlib/domain-fs.pp` and `stdlib/domain-proc.pp`. This
is real pp source you can read. It holds all the policy over the core-enforced
protocol: what counts as a create versus an update, when to restart a service.
There is no privileged reconciler engine hidden in the runtime. A domain is a
library.

== Reconciling a filesystem

`pp --reconcile ROOT prog.pp` auto-loads the fs domain and registers it with a
write capability narrowed to `ROOT`. It takes the program's final value as the
desired state of the tree under `ROOT`: a `{relative-path → content}` map. It
diffs that against the real directory by content hash and materializes missing
and changed files atomically. It also deletes files under `ROOT` that the map
does not mention. The domain is the single writer, and the write grant is your
consent to that authority. An fs write grant over `ROOT` is required. Without
it, nothing is written.

The transcript below reconciles a two-file desired state into a fresh root, so
both files appear. It then introduces drift by hand, deleting one file and
editing another, and reconciles again. The second pass reports exactly one
create and one update, and the tree is restored. The summary line pp prints
names the counts per kind. Its absolute root path is filtered to `ROOT` so the
output is machine-independent.

#example("domain-reconcile", sh: true)

Nothing in `site.pp` describes how to converge. There is no "if missing, create"
logic. It states the desired contents, and the domain works out the difference.
Reverting `conf/app.txt` and restoring the deleted `index.html` are the same
mechanism, driven entirely by the diff.

Desired contents may be inline strings, as here, or `blob:<hash>` references
into the content-addressed store — a compiled artifact ingested with `blob`. A
blob reference diffs by hash without loading its bytes. So `rm -rf` on the tree
restores from the store with zero tool re-runs when the desired-state nodes hit.

== Watching, and other domains

`pp --watch --reconcile ROOT prog.pp` runs the program, reconciles, then polls
the observed cells and re-runs on any change. This is a controller loop. Every
registered domain is re-observed and re-applied on each tick, whichever cell
changed. This is cheap when nothing moved, because the plan cache turns a no-op
pass into a hit. An externally deleted file or a drifted config is caught within
one poll interval.

The process domain is the same protocol over a different world.
`pp --supervise prog.pp` (usually with `--watch`) takes a `{service-name →
spec}` map and keeps the process table matching it. It starts missing services,
stops removed ones, and restarts a service whose spec changed. It also restarts
one killed out from under it, within a poll interval. It requires
`--grant process` and refuses stratification on its own `proc:` cells, exactly
as the fs domain does. A from-scratch third-party domain is anything with an
observe/diff/apply triple registered via `register-domain`. It gets the same
journal bracket, plan cache, verify-after-write, and stratification for free.
The protocol is generic, not filesystem-shaped.

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
