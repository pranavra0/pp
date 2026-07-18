# pp status

This file lists what pp does today, verified by running the code. Update it
as reality changes. Open discrepancies live in the ledger below; design
rationale lives in [DESIGN.md](DESIGN.md).

> Verified by *running* `dune runtest` and the fuzzer (`dune exec
> ./tools/fuzz.exe -- --grammar full`) in the repository, not by trusting
> prose.

## What pp is

pp is a Lisp with a single tree-walking evaluator engine and one
persistent, content-addressed, trace-verified build engine.

pp is a proven incremental hermetic build engine. A 101-translation-unit C
project builds through a real `build.pp` and meets every exit criterion for
that claim, checked by running it:

- a null rebuild runs 0 processes in about 130ms, with the journal as proof
- an mtime-only touch triggers 0 recompiles
- a one-file edit triggers exactly 1 compile and 1 link
- deleting the build directory restores it byte-identically from the store,
  with 0 tool re-runs
- a comment-only header edit makes dependents recompile but not relink
- authority gates apply transitively across the build (`tests/024`)

pp also builds itself through `build.pp` (`scripts/build-self.sh`), and
builds, caches, cuts off and restores Lua 5.4.7 the same way
(`scripts/build-lua.sh`).

pp also runs continuously: it can watch files and re-run on change, and it
can reconcile a filesystem tree or a set of processes against a desired
state, retrying non-convergent actions safely. It can also shard work
across a cluster of machines using signed capability tokens and a
garbage-collected store.

What this does not mean: pp is usable by strangers yet. The gaps below were
each hit in practice while proving the build engine claim above:

- Portability. The store format is portable: nothing under `~/.pp/store`
  is OCaml's Marshal format; everything is canonical s-expression text or
  raw bytes under a `VERSION` stamp (`tests/037`). CI
  (`.github/workflows/ci.yml`: `dune build`, `dune runtest`,
  the fuzzer, `scripts/build-lua.sh`) is green on both ubuntu-latest and
  macos-latest. Unicode NFC normalisation of cell ids is not implemented.
- Releases. `pp --version` and the REPL banner report a real version from
  `dune-build-info`, checked from both a git checkout and a `git archive`
  tarball with no `.git` directory. [RELEASING.md](RELEASING.md) has the
  mechanics. No tag has been cut and none is planned; release notes would
  be reconstructed from git history (Conventional Commits) when a release
  is wanted.
- Ergonomics and the standard library. Both are still thin. The worst
  footgun — `(def x v)` silently creating a nullary closure — is fixed: a
  non-list `def` is now a value binding (`tests/025`). Remaining gaps are the
  open entries in the ledger below.

## What works today

### Reading and writing programs

pp has two readers that produce the same abstract syntax tree, so a
program's identity never depends on which surface you write it in (SPEC
Appendix B). The brace-and-infix surface (`.pp`) is the default; the
original s-expression surface (`.ppl`) is what macros author and consume,
since it is the AST written out as text. `pp fmt --to-braces` and
`--to-sexpr` transpile between them losslessly, comments included. Both
readers thread source locations at the same points, so an error reports
byte-identical text whichever surface produced it (LAW-29).

The language has: mutual `let` and sequential `let*`; `and`/`or`
(desugared to `if`); `def`/`fn`/`do`, where a non-list `def` head — `let x
= v` in braces, `(def x v)` in s-expressions — is a value binding, not a
closure (letrec* scoped inside blocks, with a "referenced before its
definition" error; sequential at top level; a duplicate `def` in one block
is a read error); `node x { e }` / `(defnode x e)`, which binds the node
thunk of `e` (LAW 4, `tests/025`); `with-caps`/`perform`/`with-handler`
(the old `effect` capability-union form is removed, since it was a way to
widen authority the moment capability values existed); `module`/`import`/
`load`/`load-module`; `island`; `with-config`/`config`; `quote`/
`quasiquote`; and type annotations, checked when a value is forced, not
when it is declared (per-parameter annotations compile into checks ahead
of the function body, LAW 32, `tests/026`). Source locations are recorded
for top-level forms and around `def`/`fn`/`defnode` bodies, so parse
errors carry a file and line.

The standard library has primitives (`string-index`, `string-trim`,
`string-sub`, `number->string`, `string->number`, `map-keys`, `map-vals`,
`map-remove`, `file-exists?`, `dir?`, `argv`, `env-get`, `exit`) and
library files: `stdlib/list.pp` (map/filter/foldl/foldr/range/take/length/
each/append/reverse/nth/drop/member?), `stdlib/string.pp` (string-join/
starts-with?/ends-with?/lines), and `stdlib/map.pp` (map-has?/map-merge,
which needs `list.pp` loaded first). `assert` is a reader form that
reports the failing form's file and line. Pinned by `tests/028-stdlib.sh`
and `tests/028-stdlib.pp`.

### Evaluating programs

The tree-walking evaluator applies functions strictly, call by value.
`let` bindings become thunks, memoised through `thunk_status`, with a
trampoline that switches to a heap work queue past a depth threshold. Deep
non-tail recursion is still bounded by the OCaml stack.


Tail calls are optimised: CPS-style `eval_tail`/`apply_tail` in the
tree-walker.

Effects and handlers use a dynamic handler stack with builtin fallbacks
for read-file, write-file and log. `do` evaluates each step strictly.
exception, and a tail call.

Capability checking happens at the point a filesystem read or write is
performed, and for `slurp`, gated on `--grant process` for the `run`
effect below (LAW 22). Capability constructors were removed from user
code; authority enters a program only through `--grant`.

The tree-walker produces module values (`VEnvMap`).

### Caching and the persistent store

`node { e }` marks a thunk as persistent. `force` consults `~/.pp/store`
(result objects keyed by hash, with a set of traces per node key). A
second run of a pure node returns the stored result without re-running it,
and without replaying its `log`/stdout output (LAW 17).

The store format is portable: objects, traces, fenced-action specs and
process state serialise through a canonical, byte-stable s-expression
codec (`src/codec.ml`), with no Marshal anywhere under `~/.pp/store`. A
`~/.pp/store/VERSION` stamp invalidates an old or foreign store by wiping
`objects/`, `traces/`, `fenced-specs/` and `procs/` (never `blobs/` or
`journal/`) and re-stamping, rather than crashing. The store holds data
only: a code-valued node result, such as a closure, stays process-local —
its trace persists but no object is written, so a cross-process consumer
recomputes it. Golden byte fixtures pin the encoding (`tests/fixtures/
store-v1/`, `tests/037`).

A node's persistent key is `H(code structure ‖ free-variable value
hashes)` (LAW 20): the free variables a node references are resolved to
their value hashes; the whole-environment hash and the capability set are
excluded. Rebinding an unrelated global is a cache hit; widening `--grant`
does not invalidate a node; changing a value a node actually reads re-keys
it. Ambient config and the handler stack are excluded from the key too —
what a node observed of them lives in its trace instead, below. Pinned by
`tests/011-node-key-law20.sh` and `tests/015`.

During a node's evaluation, every read of the world (`slurp`, `perform
read-file`) is recorded as a (file cell, content hash) pair; reads
propagate to every enclosing node, so a parent's trace covers its
children's reads too. On a cache hit, the store re-checks each recorded
cell and serves the result only if every hash still matches, otherwise it
recomputes. This is what makes `node { slurp(path) }` return fresh
contents after the file changes. Pinned by `tests/010-node-cache-trace.sh`.

Because traces verify by content hash, an mtime-only touch rebuilds
nothing (LAW 21). Because a node's key includes its free variables' value
hashes, a downstream node hits when an upstream recompute produces a
byte-identical result — this is why a comment-only header edit triggers a
recompile but not a relink, whenever the build threads values through free
variables. No dirty-propagation graph is needed for pull-mode caching; a
reverse-edge graph now exists for push-mode `stabilize`, below.
Inline-nested cutoff remains future work.

`config(k)` inside a node records a `config:<k>` cell (absence is a
distinct observation); every `perform` records a `handler:<effect>` cell
holding the intercepting handler's value hash, or a builtin marker when
nothing intercepts (LAW 33/26). Both re-check the caller's ambient config
and handler stack on a hit. So changing a config value or handler a node
never observed cannot invalidate it, and a node cached under a mock
read-file and one cached under the real builtin coexist as two traces
under one key. Fixing this exposed that same-arity closures all hashed
identically; `hash_value` now hashes identity and captured frames,
guarding against cycles. Pinned by `tests/015-config-handler-cells.sh`.

A node that raises a Failure exception stores a failing trace (the error
plus the reads made up to the failure); a later force re-serves the same
error without re-running, and only re-runs when a recorded read changes
(LAW 28). A raising thunk resets out of the "evaluating" state rather than
staying stuck, which fixed a false "infinite recursion" report. Pinned by
`tests/012-node-failure-trace.sh`.

A stored result is served only if the caller's capabilities cover every
file cell in the trace's read closure (LAW 23b); since reads propagate to
enclosing nodes, this check is transitive, so a narrow caller cannot
launder a broad read through a cached aggregator. A capability denial
raises a distinct Capability_error and is never cached — authority is not
identity (LAW 15) — so a later authorized run still hits. Pinned by
`tests/013-node-hit-capability.sh`.

Capabilities can be attenuated from inside the language.
`current-capabilities()` reifies the ambient set; `cap-restrict` takes an
optional `fs_mode` argument (`:ro`/`:rw`/`:wo`, matching `--grant`'s names)
that only ever narrows a grant — requesting a wider mode is a
Capability_error. `with-caps(cap-expr) { body }` replaces the ambient
capability set with exactly the requested value, checked against the
current ambient, for the body's dynamic extent, and restores correctly on
exception and tail call.

The node boundary is enforced in both directions: a node's free variable
that holds or contains a capability is a Capability_error at
key-computation time, and a node's result containing a capability is
rejected before it can be stored. Node capture is real: a node's captured
capabilities are fixed at the point `node { e }` is created, not at the
point it is forced, so a node created under a narrowed ambient stays
denied even if later forced under a wider grant, and vice versa
(`tests/040-caps-attenuation.sh`). Adversarial coverage — forged
capability text is unparseable, composing two narrowed views cannot
resurrect the root, mode and with-caps widening are rejected, exception
and tail safety hold, node capture works via both a direct free variable
and a closure, node results are rejected, and the `effect` form is gone —
lives in `tests/capability-adversarial.sh`.

One documented gap: a capability hidden behind an unforced thunk is
invisible to this check, because forcing it just to check would itself
violate LAW 14. The actual security floor for that case is the use-time
checks (with-caps, the hit gate), not this hygiene check.

### Macros

A macro is a function from syntax-as-values to syntax-as-values:
`(defmacro (name params...) body...)` in s-expressions, or `defmacro
name(params) { body }` in braces. It receives its argument forms already
converted to values by `quote_to_value`, runs its body through the
tree-walker before ordinary source evaluation begins (LAW 36), and the result is
converted back to syntax by `Quotation.value_to_expr`.

Expansion is the one shared step (`macro.ml`) the expansion boundary passes
through before the evaluator sees a form. Because of this, LAW 20 needed no
change: a node whose body comes from a macro call is keyed on the expanded
code, so editing only the macro's definition re-keys any node that used it
(`tests/042-defmacro-rekey.sh`).

`defmacro` is not a reader special form — it parses as an ordinary
application — so the evaluator never needs to see the unexpanded macro call.
Macros are recognised only at the true top level of a file or REPL input,
sequentially, like a value def; use before definition is an ordinary
unbound-symbol error. They are not recognised inside `do`/`module`/`fn`/
`node` bodies, including node bodies specifically: a `defmacro` there is
left alone by the expander and fails as an ordinary unbound-symbol error
identically (`tests/042`).

Hygiene is manual, not automatic: `gensym(["prefix"])` produces a symbol
using `~` as a marker character the reader cannot parse, reset every run
for key stability. Covered by the fuzzer's `stmt_defmacro` arm and by
`tests/041-defmacro.pp` (control-flow macros, gensym hygiene, a macro
building a node form, nested macro use, a macro-generated def, macro
redefinition; `tests/041-defmacro.ppl` keeps the original s-expression
version, and `tests/056-defmacro-both-surfaces.sh` checks both).

### Running external tools
`perform run(cmd, args…)` runs a process. It requires `--grant process`
(denial raises Capability_error, never cached) and returns
`{"exit" int, "out" str, "err" str}`. Inside a node, the child runs
with the node's own scratch directory as its working directory;
relative slurp/read-file/write-file resolve into that scratch space,
capability-free and unrecorded; an absolute write-file inside a node is an
error (LAW 18); the scratch directory is deleted when the node's frame
pops.

Trace recording defaults to a coarse baseline: a `tool:<resolved binary>`
cell plus a `tree:<root>` whole-tree hash cell per filesystem-read grant,
so any change to the tool or anything under a granted tree re-runs the
node, including reads pp never actually saw. `perform run-dep!(DEPFILE,
CMD, ARGS…)` refines this: it runs the tool, then parses its
Makefile-style depfile, turning granted dependencies into precise `file:`
cells and out-of-grant (system) dependencies into `tool:` cells, with no
coarse `tree:` cell at all — so touching an unrelated file under a granted
root no longer re-runs the node. A missing depfile falls back to the
coarse baseline. Hit authority follows the same split: a `tree:` cell
needs the filesystem grant, a `tool:` cell needs the process grant. Pinned
by `tests/017-run-effect.sh` and `tests/022-depfile.sh`.

### Reconciling a desired state

`register-domain({:name :namespace :observe :diff :apply :write-cap
[:observe-cell]})` registers a reconciliation domain from ordinary pp
code. `observe` runs fresh every pass and is never cached. `diff` runs
pure, under an empty capability set, and is itself plan-cached, keyed on
its code plus the observed and desired values. `apply` runs under the
domain's own write capability and is journaled each pass as an
`intent`/`done` bracket whose fields are the domain's own summary. Every
domain gets its own namespace prefix, and while a domain's observe/diff/
apply/verify runs, the system suspends its own bookkeeping of what got
observed, so a domain never registers itself as a dependency of its own
write (LAW 30). After apply, the system re-observes and re-diffs; anything
still different is a hard error (verify-after-write).

Two domains ship as pp source, not OCaml: `stdlib/domain-fs.pp` and
`stdlib/domain-proc.pp` hold all the reconciliation policy; `src/
domains.ml` is the generic orchestrator (`src/reconciler.ml` and `src/
supervisor.ml` have been deleted). A third-party example domain unrelated
to files or processes — a directory of one-file-per-key values — exercises
plan caching, namespacing, capability threading (a missing grant is a
Capability_error from `cap-restrict` itself, before the domain runs), a
verify-after-write failure, the journal bracket, and correct ordering
against fenced actions (`tests/046-domains.sh`), showing the protocol is
genuinely generic.

The filesystem domain: `pp --reconcile ROOT prog.pp` auto-loads
`stdlib/domain-fs.pp`, treating the program's final value — a map of
relative paths to string contents — as the desired state under ROOT. It
diffs against content hashes read straight from the tree, with no trusted
state file, journals intent/done to `~/.pp/store/journal`, applies changes
via a temp-file-plus-rename with verify-after-write, and deletes unmanaged
files. The filesystem write grant over ROOT is required and is the
consent for this. Desired contents can be inline strings or `blob(S)`
content-addressed references; the domain compares by hash without loading
bytes, so deleting and re-reconciling a build directory restores it with
zero tool re-runs when the desired nodes hit (`tests/023`). Grant the
domain write-only access (`fs:<root>:wo`): a read-capable grant would make
`run`'s tree cell observe the domain's own output and trip the
self-dependency check. Combine with `--watch` to reconcile continuously —
every registered domain, not just this one, is re-checked each tick. Both
backends. Pinned by `tests/018-reconcile.sh`.

The process domain: `pp --supervise prog.pp` (typically `pp --watch
--supervise`) auto-loads `stdlib/domain-proc.pp`; the program's final
value is a map of service name to spec, kept in sync with observed
processes — starting missing services, stopping removed ones, and
restarting a service when its spec changes, compared structurally so key
reordering alone never triggers a restart. It reaps and restarts a service
killed with `kill -9` within one poll interval. Process state lives in
`~/.pp/store/domain-state/proc/`, and every start/stop is journaled.
Requires `--grant process`. Pinned by `tests/
033-process-reconciler.sh`.

Fenced effects handle actions that cannot simply be re-run, such as
sending an email or charging a card (LAW 31). `fenced(KIND, SPEC)`
registers such an action for reconciler sequencing and errors if used
inside a node body. Under `--reconcile` or `--supervise`, each action
executes at most once per pass, journaled as `intent fenced KEY EPOCH KIND
SPEC-HASH` before it runs and `done fenced KEY RESULT-HASH` after. On
recovery, an intent with no matching done is resolved by `--fenced-policy
retry|abort|ask`, never by silent retry. Pinned by
`tests/034-fenced-effects.sh`.

### Developer tools

`pp why file.pp` explains every node force to stderr: first build, which
trace cell went stale, an unauthorized read (with the offending cell
redacted if the caller lacks authority over it, LAW 23c), or a hit with
its verified trace. `--no-cache` skips reading the cache, so everything
recomputes, but still stores fresh results and traces. `--check` re-runs
each missed node's body and compares result hashes; a mismatch flags the
node as volatile and fails the run. Pinned by `tests/
019-why-nocache-check.sh`.

`pp --once file.pp` is the explicit one-shot mode, and the current
default. `pp --watch file.pp` runs the program, then polls observed cells
for content changes and re-runs on change, using the store's trace
verification to skip unchanged nodes and recompute changed ones — proving
`--watch` and `--once` collapse to the same store-level behaviour. `pp
graph file.pp` runs the program, then scans `~/.pp/store/traces/` and
prints the cell-to-node dependency graph. Pinned by
`tests/031-watch-once.sh`.

`pp --watch --stabilize` uses a reverse-edge index built from stored
traces to compute exactly which node keys go dirty when a cell changes,
and resets only those thunks, so clean nodes skip the cache check entirely
on re-execution. It produces identical results to the polling `--watch`
loop across the `tests/032` battery of cell-change sequences. Pinned by
`tests/032-stabilize.sh`.

`load`/`load-module`/`island` are confined to the CLI programs' own
directories, the current directory, and `~/.pp`; anywhere else is an error
regardless of grants. These reads are recorded as `runtime:file:` cells,
which affect cache validity but are exempt from capability checks
(LAW 24). Pinned by `tests/020-loader-authority.sh`.

Every cell id — `file:`, `tree:`, `stat:`, `tool:`, `runtime:file:` — is
built from one canonicalisation function: absolute real path, symlinks
resolved, no trailing slash; a path that does not exist yet canonicalises
its longest existing prefix and appends the rest lexically, so a write
target's cell id stays stable across its own creation. This is applied at
every cell-construction site, at `--grant fs:...` parse time, and at the
loader boundary, so a symlinked source tree, macOS's `/var` versus
`/private/var`, and a trailing-slash grant are all one cell (LAW 23).
Unicode NFC normalisation is a documented gap, not yet implemented. Both
backends. Pinned by `tests/036-canonical-cells.sh`.

Cell naming, observation, record/replay, and hit authorization now meet at the
exhaustive `Observation` boundary. Probe and domain registries are owned by the
session and are consulted directly. The unused `Proc` cell constructor and
observer hook are gone;
legacy `proc:` trace ids remain parseable as unknown cells and force a safe
miss.

The first observation of a file cell ingests its bytes into
`~/.pp/store/blobs/<sha256>` and pins the (cell, hash) mapping for the
rest of the run; every later read of that cell, at any tier, serves the
pinned copy. So one run sees one snapshot of the world, and a torn read —
an external writer mutating a file mid-run — is invisible until the next
run. pp's own write-file unpins a cell so its own writes stay coherent.
Pinned by `tests/021-cas-ingest.sh`. Under parallel scheduling, N forked
workers each inherit the pin table as of the fork instant, then pin their
own later reads independently — so one parallel run guarantees only "at
most N snapshots agreeing on everything pinned before dispatch", narrower
than the single-process guarantee above but still sound: a divergent
observed world is a legitimate distinct trace, and the worst case is an
extra recompute, never a wrong cache hit. A snapshot barrier, or storing
pins, remains future design work (see DESIGN.md).

### Running work in parallel

`--schedule serial|parallel:N|race:N` (`src/scheduler.ml`) forks worker
processes at the point where a batch of persistent nodes misses the
cache. The `map` builtin, which does not force its arguments, builds a
batch of unforced node thunks; `force-deep` collects every reachable
unevaluated node; the batch is then dispatched — `parallel:N` forks a wave
capped at N concurrent workers, `race:N` forks N redundant workers for one
job and keeps the first success, killing the rest. Only after dispatch
does the ordinary recursive walk run, and by then every node it reaches is
a store hit. A single forced node that misses only forks under `race:N`
(redundant workers); under `serial` or `parallel:N` a lone miss stays
in-process, since forking buys nothing for a batch of one.

A worker runs exactly the same function the serial code path calls, and
exits 0 or 1; the parent never reads a value from a child, only checks the
store after reaping, so a dead worker just degrades to an ordinary serial
recompute. `--schedule` is ambient — read only by the miss code path and
the scheduler, never part of a node's key or trace. `--check` under a
non-serial schedule re-runs the whole program forced serial against the
same store and fails on any mismatch, auditing that the schedule choice
never changes the result.

The store is hardened for concurrent writers: a per-key file lock guards
the trace read-modify-write cycle (disableable via `PP_TRACE_LOCK=0`,
exercised by `tests/038`), and the journal writer uses one atomic write
per line so concurrent writers cannot tear or drop each other's entries.
The 101-translation-unit build under `parallel:N` is about 3.3 times
faster than serial from a clean build, with a byte-identical result
(`tests/024`'s `p3-*` assertions). `race:3`, many-writer, and
same-key-without-lock stress cases, plus a check that `fenced(...)` still
raises correctly inside a node under every schedule, are covered by
`tests/038`.

### The REPL

The REPL supports multi-line input (paren-balanced, string- and
comment-aware), a `~/.pp/history` file with Up/Down recall, raw-mode line
editing on a terminal, deep-forced result printing, and `:why on|off` /
`:help` / `:quit`. A piped session has no prompt and no banner.
Pinned by `tests/029-repl.sh`.

### Probes, sealed values and network access

`register-probe(name, observe-fn, read-cap)` and `probe(name)` are the one
sanctioned source of non-deterministic data in a node (LAW 37/38). The
observe function runs at most once per pass, outside the reading node's
trace stack and under exactly its registered read capability, so its own
reads never contaminate the reading node's trace. The reading node instead
records a `probe:<name>` cell — a hash of the observed value — with no
capability needed at the read site, since the authority was already spent
evaluating the probe once. Results are pinned in memory only and cleared
at the same points the store's run-level pins are cleared; nothing a probe
returns is ever written to `~/.pp/store`. Reading an unregistered probe
name is a hard error. Pinned by `tests/043-probes.sh`.

`--grant secret:<path>` mints a secret capability, canonicalised like
filesystem grants (LAW 39). `slurp`/`perform read-file` dispatch on which
grant covers the path: a filesystem grant, with or without a secret grant
too, returns an ordinary string, unchanged; a secret-only grant returns a
sealed value, read from an in-memory pin and recorded as a `sealed:<path>`
cell — its bytes are never written to a blob. Every printer redacts a
sealed value to `#<sealed>`, and the codec refuses to encode it, so it can
never reach the store as data either way. The node boundary bans a sealed
value exactly like a capability, in both directions. Serving a cached hit
on a sealed cell requires a covering secret grant.
`unseal(v)` is the one explicit way to get the string back — there is no
other path. A recursive scan of `~/.pp/store` after a program reads a
secret, and separately after one that unseals it, finds no secret bytes
anywhere. Pinned by `tests/044-sealed.sh`.

`--grant net:<host>[:<port>]` mints a network capability (`host = "*"`
wildcards; an unspecified port is unrestricted). `perform http-get(url)` /
`perform http-post(url, body)` fork `curl` rather than adding any
networking code, and are authorized against the network capability, not
the process one, since "may read this host" is a narrower claim than "may
execute anything". Both are banned inside node bodies, since a network
read is neither the declared non-determinism mechanism nor convergent, so
it has no sound cached meaning. Results are `{"status" int, "body"
string}`; a missing `curl` binary is a clean error. Pinned
by `tests/045-network.sh`, which skips cleanly if `curl` or `python3` is
absent.

### Two readers, one language

pp has a second reader (`src/reader_braces.ml`) for a brace-and-infix
surface, parsing to the exact same `Core_model.expr` the original s-expression
reader always produced. Since LAW 20 keys computations on expanded code,
surface syntax was never part of a program's identity, so this needed no
change to node keys. The fuzzer checks print-then-reread and LAW-20 hash
equality across both grammars. `pp fmt --to-braces`/
`--to-sexpr` is the lossless, comment-preserving transpiler.

The whole tree — the standard library, `build.pp`, all 16 `tests/*.pp`
programs, examples, the demo, and the manual's executed examples — has
been mechanically transpiled, with `build-self.sh` and `build-lua.sh`
null-rebuilding with zero recomputes against a store populated before the
migration, and the test suite green throughout. Braces are now the
default (`.pp`); s-expressions are the alternate surface (`.ppl`)
(`tests/054-brace-reader.sh`, `tests/055-fmt.sh`). The REPL and `-e` read
braces; `pp why`, error messages and `pp graph` print braces. The manual,
README, SPEC law examples and glossary use the brace surface throughout,
keeping s-expressions only where quotation or macro or AST-identity is
literally the point.

This surface migration changed no evaluator, macro expander, store, codec,
hasher, trace or capability code: a diff of `src/*.ml` outside
`reader_braces.ml` and `main.ml`'s new `fmt` dispatch is empty.

### An end-to-end demonstration

`demo/deploy.pp` is a pure dispatcher from host to domain to desired
state: it builds a C service once via `run-dep!`, then renders each host's
config in a node that unseals that host's secret key and emits only a
hash of it, never the value. `demo/agent.pp` is byte-identical for every
host: it registers the filesystem and process domains under its own
grants, pulls its own slice of the desired state, and registers a
report-only health probe. `demo/src/greeter.c` is the service being
deployed.

Together these compose every capability described above, with no changes
to any `src/*.ml` file: build, a two-host deploy, drift convergence, `kill
-9` recovery, secret rotation (only the hash changes; the bytes never
touch `~/.pp/store`), and a `pp why` audit that redacts the sealed cell
for an unauthorized caller. All 12 combinations of backend, scheduler and
placement agree: the six pull-mode combinations produce an identical
desired-state hash, `--check` passes for parallel and remote schedules,
and the six push-mode combinations settle to a byte-identical tree.
Pinned by `tests/052-devops-complete.sh` (55 assertions). dune's runtest
rule mirrors the demo directory into the build root so this stays
reproducible.

A companion seam makes desired state that depends on a probe reproducible
too. `--pin-file <path>` pre-seeds the pin table before a program runs at
all; a `(pin-probe "NAME" value)` line pins one probe's value directly,
ahead of its observe function ever running. `--dump-pins <path>` writes
out every pin and every probe value from a run. `demo/volatile-deploy.pp`
deliberately folds `probe("replica-count")` into its own desired state, so
its published hash tracks a metrics file's current content — proven
genuinely volatile, since two unpinned runs with different file content
publish different hashes. `--pin-file` on a dump then reproduces the same
canonical hash across all 6 pull-mode combinations even after the metrics
file changes again, with the probe's observe function proven never to run
at all. Push-mode combinations are not wired for this adversarial program,
since it registers no domain and so has no tree to converge. Pinned by
`tests/053-pin-observations.sh`.

### Running across a cluster

Gated on a written threat model (`docs/THREAT-MODEL-cluster.md`). `pp
cluster-init` mints a 32-byte random secret and a cluster id under
`~/.pp/cluster`, refusing to overwrite an existing one. A signed cluster
token (`src/token.ml`) is canonical text, minted from the same `--grant`
grammar strings `pp --grant` itself parses, so both share one parser.
Verifying a token checks its signature, then cluster id, then expiry, then
capabilities, in that order, so a forged token never reaches the
capability parser.

`src/transport.ml` defines a transport interface for pushing and pulling
hash-named objects, blobs and traces, plus a control channel, with a
local-directory implementation (used by CI) and an ssh implementation that
is currently a stub. The receiving side always re-hashes an incoming
object, blob or trace line before accepting it, and rejects anything that
doesn't match or doesn't parse — the only functions in the module allowed
to write a remote-sourced artefact into the local store. Serving a cache
hit to a remote caller verifies their token, then runs the exact same
authority check a local hit would, so a hit only ever pushes the traces
that token's capabilities cover; a miss or a denied token pushes nothing.
Sealed values remain unshippable by construction. Two `pp` invocations
differing only in `$HOME` stand in for two cluster members in tests.
Pinned by `tests/047-cluster-sync.sh`: corrupted objects, blobs or traces
are rejected; tampered or expired tokens are denied; the authority check
holds across the wire; why-redaction survives a sync; no secret bytes ever
cross; and the result hash is identical whether built locally,
independently, or served from a remote hit.

Work can be scheduled onto a specific cluster member: `--schedule
remote:<member>` looks up a member's store path from
`~/.pp/cluster/members` or `$PP_CLUSTER_MEMBERS` — an address, never a
capability grant. A batch of nodes is shipped to a member only if its free
variables are all plain data — a reference to a global builtin is
allowed, since it is identical code on both sides by construction, but a
captured closure is not and stays local. Shipping a batch pre-observes the
granted filesystem scope, pushes those files into the member's own store
as blobs, mints a token from this process's own grants, and spawns the
member as an ordinary second `pp` invocation of the same program, with its
own `$HOME`, running serial. Results are pulled back through the same
re-hash-verified path used for a local sync. This also extends to `blob:`
references embedded in a node's own result, not just its trace.

Pre-seeding a member's file cells before it runs is unbypassable by
construction, since the store's pin table is always consulted before a
disk read; `tool:` cells are deliberately not pre-seeded, since the
member's own toolchain is a legitimate observation of its own. Every
failure mode — an unknown or unreachable member, a member that crashes, a
non-shippable free variable, a malformed reply — leaves the affected keys
as an ordinary cache miss, computed locally exactly as a dead local worker
would be, never a wrong answer or a hang. A stdlib bug once defeated this
batching for any `--reconcile`-based build: `list.pp`'s own pp-level `map`
shadowed the batching-aware `map` builtin, so nodes were forced one at a
time and never dispatched in parallel at all. That bug is now fixed (see
the discrepancy ledger, D26); this test still exercises the scheduler via
direct `write-file` materialization rather than `--reconcile`. Pinned by
`tests/048-remote-placement.sh` (an 8-translation-unit build with a real C
compiler, byte-identical to a serial build; a cross-machine cache hit; the
differing-file pinning case; a non-shippable value staying local; an
unreachable member degrading cleanly).

The desired state passed to a domain can itself be host-qualified: `{host
-> {domain -> desired}}`. `--member-name <n>` opts a run into taking only
its own slice of that map; without the flag, the whole map reaches the
domain orchestrator completely unchanged, which is why every earlier test
(`tests/018`, `033`, `046`, `047`, `048`) still passes unmodified. An
unknown `--member-name` is a hard error. A member is simply `pp --watch
[--supervise] --member-name <n>` running its own slice, so `kill -9`
recovery works exactly as it does on one machine. Pinned by
`tests/049-host-domains.sh`.

A desired state can also be published and pulled by hash rather than
re-derived from source each time: `--publish-object <shared-root>` runs a
program, stores its forced value as a content-addressed object, and
pushes it plus every blob it references into a shared root.
`--desired-object <hash> <shared-root>` pulls both back, re-hash-verified,
and substitutes them for the desired state entirely — the recorded
program still runs, for its domain-registration side effects, but its
return value is discarded. This never syncs fenced actions or journals,
only the value and its blobs. Pinned by `tests/051-cluster-exit.sh`.

`pp gc` frees old store entries, explicitly and never automatically. Its
roots are the last few reconciliation passes' desired-state hashes,
recorded in a frozen journal entry and a companion manifest capped at
`--gc-keep-epochs` (default 5). It marks live data by replay: since a
trace does not record which nodes it touched, `pp gc` re-runs each
recorded root as an ordinary `pp` subprocess with the same files, grants
and flags, which marks every trace, object and blob it hits as live — but
skips applying any domain or fenced action, so a mark pass can never write
to the world except by an ordinary, idempotent recompute if something has
genuinely drifted since the epoch. It sweeps only `objects/`, `traces/`
and `blobs/`, never `fenced-specs/`, `procs/`, `journal/` or the islands
cache. A grace period (default 2 seconds) protects anything created
recently, a re-check immediately before each delete protects against a
concurrent reconciliation pass, and the whole sweep is refused if even one
recorded root fails to replay. Pinned by `tests/050-gc.sh`: store size
stays bounded across repeated reconciliation passes and a genuine
concurrent watch loop; a kept root's closure survives as a pure cache
hit; a concurrent parallel build racing gc neither crashes nor loses data;
the islands cache is untouched; an empty store is a clean no-op.

What's proven and what a real cluster still needs: host-qualified slicing
and the by-hash publish/pull seam are both real, tested across genuinely
separate `$HOME` directories. What remains loopback-only is the transport
underneath (ssh is still a stub) and the policy for which member runs
which host's slice — a hand-written members file today, not service
discovery. GC's mark-by-replay is a genuine subprocess re-run, not a
simulation.

## Discrepancy ledger

This is the punch list. "Fixed" means fixed and covered by a test.

| # | Claim | Reality |
|---|---|---|
| D1 | Caching works across runs | Fixed. Node results and their verifying traces persist to `~/.pp/store` across processes. A hit re-verifies the node's recorded reads before serving (`tests/010`); nodes key on code plus free-variable value hashes, excluding environment and capabilities (`tests/011`); failures are memoised as failing traces (LAW 28, `tests/012`); hits are gated on the caller's authority over the transitive read closure (LAW 23b, `tests/013`); config and handler observations are trace cells, not key material (`tests/015`); value-keyed cutoff works (`tests/016`); the run effect records `tool:`/`tree:` cells (`tests/017`). The filesystem and process domains (`stdlib/domain-fs.pp`, `stdlib/domain-proc.pp`) now provide the reconciler this row originally flagged as missing. |
| D2 | Islands fetch, pin and cache modules | Fixed. `(island <uri> "64-hex-pin")` is a content-addressed module: the pin is part of the code hash, so identity is structural, with no lockfile and no extra cell. It names an immutable tree under `~/.pp/islands/src/<pin>/`, checked against the pin on every resolve; tampering is a hard error. The tree-walker evaluates the pinned `entry.pp` as a module. An unpinned form is a hard error naming the fix. `pp --update` re-resolves and rewrites pins in the source, refusing rather than half-writing. Fetching over git/github is opt-in (`--fetch-islands`), journaled, and governed by `THREAT-MODEL-islands.md`. `pp island-pins` inspects pins; `pp why` reports source drift. Pinned by `tests/035` and `tests/005`. |
| D4 | Deep thunk chains are handled | Partial. The trampoline handles forced thunk chains; deep non-tail evaluation recursion is still bounded by the OCaml stack. |
| D5 | Hashing uses SHA-256 | Fixed. `hash_string` uses Cryptokit's SHA-256. |
| D6 | Same hash means same thunk | Fixed. A closure's hash previously omitted its captured environment, so two colliding closures could return the wrong memoised result in the tree-walker. Fixed by folding the captured environment's hash into the closure hash, at constant time, with no traversal. Pinned by `tests/009`. |
| D8 | Capabilities are the whole security story | Mostly fixed. Path checks are component-aware and check the full path; `slurp` is gated; `random`, `CapTime` and `CapMemory` have been removed. Cache hits are gated on the caller's authority over the trace's transitive read closure; denials raise a distinct Capability_error and are not memoised. Loader reads (`load`/`island`) run under interpreter authority bounded to source roots plus `~/.pp`, traced as authority-exempt `runtime:file:` cells. |
| D10 | Fexprs are operatives over syntax | Cut, and replaced. `def-fexpr` has been removed. Metaprogramming is served instead by `quote`/`quasiquote` and `defmacro`: one shared expansion point, `value_to_expr` as `quote_to_value`'s inverse, and `gensym` for manual hygiene (`tests/041`, `tests/042-defmacro-rekey.sh`). |
| D11 | Quasiquote works | Fixed. The reader parses quasiquote, unquote and splicing; a runtime walker expands them, including nested forms, vectors and maps. |
| D12 | Source locations are reported | Fixed. The reader emits locations and wraps `def`/`fn`/`defnode` bodies; the shared top-level driver appends a file and line to any unlocated runtime error, never doubled. Arity errors name the callee, capability errors name the operation, unbound-symbol text is consistent, and an uncaught error prints as one line and exits 1 (`tests/027`). Errors inside a loaded file now cite that file's own line, not the loading form's line (`tests/027`, case g). |
| D13 | pp can run build tools as part of the language | Mostly fixed. `perform run(cmd, args…)` runs a process, gated on `--grant process`, returning `{"exit","out","err"}`, running with the node's sandbox as its working directory, and recording `tool:`/`tree:` cells so a tool or tree change invalidates the cached result. `write-file` inside a node is sandbox-scratch only. Pinned by `tests/017-run-effect.sh`. Remaining: `build.pp` itself needs nothing more to be written. |
| D14 | `pc.pp` self-hosts the compiler | Cut. `pc.pp` and its test have been deleted. |
| D16 | Error semantics are correct | Mostly fixed. A raising thunk resets rather than sticking, so the fake infinite-recursion report is gone (`tests/012`). A failing node run is memoised as a failing trace and re-served until a recorded read changes (LAW 28). Exception-safe state restore for effect/handler/config scopes was already fixed. Remaining: only Failure exceptions are cached; reconciler-scoped failure epochs are future work. |
| D17 | Handlers and caching interact correctly | Fixed. The handler stack was not part of the thunk key, so a thunk memoised under one handler could be served under a different one. Fixed by folding each handler's value hash into the thunk key. Pinned by `tests/009`. At node granularity the handler stack is not key material at all — each perform records a `handler:<effect>` trace cell, re-checked at hit time (`tests/015`). |
| D18 | Capabilities cannot be minted from user code | Fixed. `filesystem`, `network` and `process` are no longer builtins; capabilities enter only through `--grant`. |
| D19 | The language is homoiconic | Fixed. `quote_to_value` handles every expression form; quasiquote expands at runtime. |
| D25 | `let`-memoisation cannot silently cache a repeated `perform` call | Fixed, with an ongoing authoring discipline rather than a language change. A zero-argument closure containing a `perform`, called twice in the same dynamic extent with an unchanging environment and capability set, keyed identically under LAW 20 and silently replayed its first result instead of reading reality again — invisibly, with no error. Found in `stdlib/domain-proc.pp`, where a killed service could look "still alive" one call later. Fixed two ways: the domain orchestrator now pushes a fresh config layer, folded into the key, before every top-level observe/apply call, so the two calls a pass makes always get distinct keys; and, within a single call, the rule is now to never call a zero-argument `perform`-containing accessor more than once per dynamic extent — read it once and thread the result through as an ordinary argument instead. `stdlib/domain-proc.pp`'s own bookkeeping was restructured this way. |
| D26 | Parallel scheduling actually parallelises reconciler builds | Fixed. Two bugs stacked. First, `stdlib/list.pp` defined its own pp-level `map`, which shadowed the batching-aware `map` builtin; because application is strict, this `map` forced each node inline, so the parallel dispatcher never saw any unevaluated nodes to batch — and since `--reconcile` and `--supervise` both auto-load `list.pp`, every reconciler-based build silently ran its work one item at a time under parallel or race scheduling or remote placement. Fixed by removing the pp-level `map`, with a note against re-adding it. Second, the `pp` binary loads the standard library from dune's build mirror, which a plain `dune build` was not refreshing — only `dune runtest` was — so the same program could fork six workers on one run and zero on the next, depending on which command last ran. Fixed by tying the standard library's mirror to dune's default build alias. `tests/024` now asserts a minimum fork count directly, via a fork-count log, rather than only a soft timing check: with both fixes in place, the 101-translation-unit build forks 101 of 101 compiles and runs about 3.3 times faster than serial, from a clean build. |
