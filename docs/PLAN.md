# pp PLAN — the open work, in order

The one plan document. It contains only work that is not done. When an
item lands, it is deleted from this file: git history is the record, and
there is no "done" section. For what works today, see
[STATUS.md](STATUS.md). For why the design is shaped this way, see
[DESIGN.md](DESIGN.md).

This file absorbed FUTURE-ARCHITECTURE.md and the still-open residue of
MASTER-PLAN.md and ROADMAP.md. Those documents, and every item they had
already delivered, live in git history.

---

## 0. The criterion

Rigor by construction, simplicity by subtraction.

A ratchet (a drift test, a CI rule, a coverage check) is scar tissue: it
exists because the design still permits a mistake. The rigorous and
simple system is the one where the mistake is inexpressible, usually
because the thing that could drift no longer has a copy to drift from.
So this plan adds no new kinds of anything. Its one admission rule:

> A change is accepted only if it net-deletes: copies, mechanisms, global
> names, rules someone must remember, or tests that exist only to guard a
> seam. A change that adds a concept must retire at least two.

One corollary:

> A copy is sanctioned only when its divergence is loud and the
> redundancy is itself the verification. Two independent engines whose
> disagreement fails a differential suite are an oracle. Two helpers in
> two files whose disagreement fails silently are a trap. pp keeps
> exactly one copy of the first kind and zero of the second.

Every stage ends green: `dune runtest`, the differential suite, and the
fuzzer. On-disk formats (cell-id strings, journal grammar, codec, store
layout) stay frozen throughout: types and moves wrap representations,
never change them. Any stage that regenerates the store-v1 golden
fixture has violated this plan.

---

## Part 0 — Correctness owed now

Known divergences fixed before, or alongside, the refactor. Correct
doesn't wait for pristine.

- The VM and tree-walker diverge on module-level scoping: a module can
  see a name bound by a top-level `let` in one engine but not the other.
  This is open in the STATUS ledger; fix and pin differentially.
- The VM's dynamic-extent scoping for `with-handler`/`with-config` is not
  exception-safe. The dynamic-extent rework later in this plan (see "Hold
  dynamic extent with OCaml 5 effect handlers") deletes this whole
  mechanism class; fix there if that work is near, otherwise patch and
  pin now.
- Two fuzzer gates promised as fuzzer-integrated checks exist only as
  fixed tests: the quasiquote-parity gate and the match-shadow case
  (`tests/061*`, `tests/063`). Either integrate them into `tools/fuzz.ml`
  generation, or explicitly re-scope to the fixed tests.

---

## Part I — Subtraction (remaining)

The global-state collapse into `backend.ml` and the invocation record,
the five literal-copy deletions, and the two-parser unification in
`reader_braces.ml` have all landed, as has rendering each surface from
one typed table — the CLI flag table (parse, dispatch and `--help` from
one row set), the per-family primitive registrars, the uniform lint rule
list, and the single test-harness loop over `tests/*.sh`. Two residues
of that work remain.

### Finish the CLI restructure around the flag table

The flag table lands: parsing, dispatch and `--help` iterate one typed
row set in `main.ml`, so a flag cannot be documented-but-not-parsed. Not
yet done: `main`'s inline closures (`watch_loop`, `select_member_slice`,
`build_all_desired`, and others) are still nested in `main ()`. Promote
them to top-level functions over the invocation record, so `main ()`
reads read-table, then build-invocation, then dispatch.

### Extract tests/lib.sh

The harness loop lands; the per-script preamble does not. Extract
`tests/lib.sh` for the `ok`/`bad` plus `PP` default plus `mktemp -d`
preamble that more than 26 scripts each re-declare, and migrate every
sharing script to source it in one pass — all-or-nothing, so no script
is left with its own copy beside the shared one. (`assert` stays
per-script: its shape differs by suite.)

---

## Part II — Construction

Ordered deliberately: types first, identity unified second, the extent
mechanism third, and the build boundary with the `.mli` freeze last.
Signatures are frozen only after the type, identity and extent work have
reshaped what they describe.

### Make capabilities and canonical paths unforgeable types

Both are subtraction wearing type clothing: each makes a catastrophic,
silent mistake inexpressible, and thereby retires the prose, review
vigilance, and negative tests that currently guard it. No other new
types belong in this stage (no phantom-tagged hashes, no second AST, no
functors: each was weighed and fails the criterion in section 0).

- `Capability.t` becomes abstract. The `capability` variant references
  nothing else in `types.ml`'s recursive group, so it extracts cleanly
  into an early-compiled module whose `.mli` exposes `mint` (called from
  exactly one CLI site), `restrict`, `compose`, `subseteq`, the
  per-channel `check_*` functions, and `hash` — and no constructors. The
  unforgeable, root-minted capability rule (SPEC law 22: user code
  narrows and unions, never constructs) stops being a discipline and
  becomes a fact about which functions return `t`, for OCaml-side code
  too, which today can fabricate `CapFilesystem {path="/"; mode=ReadWrite}`
  anywhere. Rename `token.ml` to `cap_token.ml` while it's on the bench,
  since it collides with the lexing concept.
- `Path.canonical = private string`. DESIGN section 2.1's law says a
  path is canonicalized once, so the bug class where two spellings of
  one path bypass authority checks cannot reappear. Today that only
  holds by discipline: any new call site can hand a raw symlinked path
  to an authority check. Give `canonicalize` the only constructor;
  `Paths.under`, `Cell.File`, capability checks, and sandbox and loader
  containment all take `canonical`. `private` (not abstract) keeps
  reads, printing, and hashing zero-cost. The kernel/syscall tension,
  decided now: canonicalization is `realpath`, a syscall, but `path.ml`
  must live in the syscall-free kernel (see "Split out a pure kernel
  library and freeze signatures"). So the kernel signature is
  `val canonicalize : realpath:(string -> string) -> string ->
  canonical`. The resolver is injected, the kernel stays pure, and the
  sole partial application (`~realpath:Unix.realpath`) lives in the
  backend record introduced by the global-state collapse: one blessed
  construction site.

### One node-key construction shared by both engines

The two execution engines are a sanctioned copy under the section 0
corollary: their divergence is loud, and the differential suite is the
verification. What that sanction does not cover is identity: the node-key
construction (the node-key hashing rules, SPEC law 20 — the
`["node-key"; hash_expr e]` / `["fv"; name; hv]` skeleton, plus the
capability/sealed free-var ban) is written twice (`evaluator.ml`'s
`node_key_of`, `vm.ml`'s `vm_node_key`), with a comment demanding the
formats stay byte-identical. An identity divergence would not fail a
differential assertion; it would silently split the store.

How:
- Extract the key skeleton into the kernel: one function beside the
  hasher, given the expr hash and the free variables (name to forced
  value), builds the key and enforces the authority ban. `node_key_of`
  and `vm_node_key` become about 10-line adapters supplying only what
  genuinely differs: free-var enumeration and each engine's force.
  "Must stay byte-identical" stops being a comment and becomes the
  absence of a second implementation.
- Make the rebuilder one findable file. Its implementation is currently
  smeared across `evaluator.ml` (`force_node`, `run_node_body`,
  `cell_authorized_for`), `store.ml` (`hit`), and `runtime.ml` (trace
  frames). Move, don't rewrite, it into `node.ml`, with the key skeleton
  and both adapters in one place. `tests/010` to `tests/024` pin the
  move.
- Declare which engine is normative: one sentence in DESIGN.md stating
  that the tree-walker is the executable specification and the VM
  conforms. When they disagree, the differential suite has found a VM
  bug, unless the spec is shown wrong.
- Deliberately not done: deleting either engine (the redundancy is the
  oracle), and generating one engine from the other (a generator is a
  third implementation of the semantics, which fails the section 0
  criterion).

Deletes: the second key implementation, the byte-identical-by-discipline
rule and the review vigilance behind it, and the standing ambiguity over
which engine to trust when they disagree.

### Hold dynamic extent with OCaml 5 effect handlers

What exists: pp's dynamic-extent semantics run as four parallel global
stacks in `runtime.ml` (`handler_stack`, `current_capabilities`,
`config_stack`, `trace_stack`, plus `sandbox_stack`), maintained by
hand-rolled dynamic-wind at every extent boundary: `with_ref` in the
evaluator, a shadow `handler_save_stack` in the VM whose `POP_HANDLER`
must restore exactly (the VM handler-restore bug), `pop_trace_frame`'s
mirrored dual-pop, and both engines' `init` resetting the refs. The
mistake class — an extent exited without restoring, restored out of
order, or restored on the normal path but not the raising one — stays
expressible at every site and is guarded only by review.

OCaml 5 effect handlers hold dynamic extent in the language runtime
instead: `try_with` installs a frame, and leaving it (normal return, pp
condition, or OCaml exception) unwinds it, by construction.

How:
- One kernel module declares the effects, one per ambient question:
  handler lookup by name, ambient capability set, config lookup,
  trace-read recording, sandbox resolution.
- Extent constructs install handlers in both engines. `with-handler`,
  `with-caps` and `with-config` become `try_with` around the body; in
  the VM, the `WITH_HANDLER` arm re-enters `run` under `try_with`,
  deleting `handler_save_stack` and `POP_HANDLER` outright. A node force
  installs one frame owning its trace list and its sandbox slot; sandbox
  teardown is that handler's finalizer, so "every exit path" becomes the
  only path.
- Trace recording composes instead of iterating a global: each frame's
  handler appends to its own list and re-performs outward, so "recorded
  into all active frames" falls out of deep-handler forwarding.
- Fork-based worker isolation (the design chosen in DESIGN.md) is
  preserved by the same mechanism: handler frames live on the OCaml
  stack, `Unix.fork` copies the stack, and the child continues under
  byte-identical extents.
- Identity is untouched: the node-key hashing rules (SPEC law 20) never
  read ambient state, and node capture (SPEC law 23b) is unchanged in
  meaning. The differential suite and the golden fixture gate the
  conversion.
- The cost: `(ocaml (>= 4.14))` becomes `(>= 5.1)`, the
  one dependency-floor change in this plan (the development switch is
  already 5.4). This stage is severable; nothing else depends on it.
  But the default is to move: the floor buys deleting an entire
  expressible-mistake class.

Deletes: `with_ref`, `handler_save_stack` plus `POP_HANDLER`'s
exact-restore discipline, `pop_trace_frame`'s mirrored dual-pop, the two
engine-init resets, the four-parallel-stacks-in-sync rule, and the
global refs themselves: the whole expressible class of unbalanced
dynamic extent, which no test can pin exhaustively.

### Split out a pure kernel library and freeze signatures

This comes last in Part II by design: `.mli`s freeze surfaces, so they
should be written against the shape that the type, identity and extent
work leaves behind.

- One library: `src/dune`'s flat 47-module executable becomes library
  `pp` plus a thin `main` executable. One split, not several: the
  kernel is pure. The identity, authority, naming and codec modules
  (`types`'s successors, `hasher`, `cell`, `capability`, `path`, `codec`,
  `surface_tables`, `cap_token`, and the effect declarations from the
  dynamic-extent work) live in a `pp.kernel` sub-library that lists no
  `unix`. That single boundary makes "keep the oracle auditable" a build
  fact, and lets tests and the fuzzer link the reader, printer and
  evaluator in-process (today's fuzzer can only shell out to the
  binary).
- `.mli` for the remaining wide-open modules: `evaluator`, `compiler`,
  `vm`, `reader`, `reader_braces`, `macro`, and `types`'s successors.
  Each is the inferred signature trimmed to what its callers use.
- Explain or drop `-no-strict-sequence` (`src/dune`, `tools/dune`): the
  only unexplained flag in the build.

---

## Part III — The sweep (prod-readiness)

Run after Parts I and II, so it sweeps the final shape rather than a
moving target.

### Delete everything dead

This is a one-time audit, not new CI, covering files, directories and
docs:
- every file in `src/`, `scripts/`, `tools/`, `demo/`, `examples/` and
  `fuzz-failures/` is either reachable from the build or test graph, or
  deleted.
- every top-level directory gets one line in the README's layout section
  stating its purpose; a directory that cannot fill in that line
  honestly gets merged or deleted.
- each file in `docs/` opens by stating what question it answers;
  superseded plan documents are deleted, not archived, since git history
  is the archive; ARCHITECTURE.md's file table and pipeline diagram get
  re-pointed at the tree produced by the kernel-library split; delivery
  narrative moves out of DESIGN.md, which keeps only the timeless
  rationale.

### Rewrite comments to state invariants

A comment must be understandable with no other document open beside it.
After that, one trailing pointer is welcome, but only to stable
vocabulary: SPEC laws and GLOSSARY terms. Milestone letters, plan
phases, "this commit", and test numbers used as justification are
temporal scaffolding: true while the work happened, noise after merge.

The pass: grep for temporal patterns (`M[0-9]`, phase letters,
`stage [A-C]`, `PLAN-`, `tests/[0-9]` inside `.ml` comments, "this
commit"). At each hit, rewrite the comment to state the invariant in
place. Delete outright the comments that only justified a diff to its
reviewer. Fix known-stale headers: `evaluator.ml:1` still reads "lazy,
call-by-need evaluator", a description retired by a DESIGN.md decision
on evaluation order.

This is a one-time editorial pass plus a review norm, deliberately not a
lint rule.

---

## Loose ends (small, independent, grab-bag)

- SPEC caption re-pass: several law status captions are stale, citing
  blockers ("process domain absent", "reconciled domains absent",
  "awaits schedulers") that later work has since resolved. Re-verify
  each partial law's caption against reality; the substantive partials
  (SPEC laws 3, 11 and 20 on binding order and deep recursion; law 21 on
  inline-nested cutoff; laws 8 and 19 on the VM dedup mirror) stay
  honestly partial.
- NFC Unicode normalization for cell-id canonicalization is still
  unimplemented (`runtime.ml` says so): a documented residual until a
  dependency-free path exists.
- `reader_braces.ml`'s `looks_incomplete` still decides REPL
  continuation by substring-matching exception text (`<eof>`,
  `unterminated`, `unexpected end of input`). Replace it with a
  dedicated exception raised at the actual out-of-input sites, so reader
  error wording and REPL behaviour decouple. Left over from the
  parser unification, which deleted the parallel parser but not this
  stringly control-flow path.
- Test-suite speed: `dune runtest` runs one dune rule that calls
  `scripts/run-tests.sh` sequentially. Measured total wall time is 208
  seconds, and dune adds no parallelism on top. Four tests account for
  80% of that time:
  - `tests/052-devops-complete.sh`, 95 seconds: a 6-variant schedule
    matrix, each variant doing a real `cc` compile and process restart.
  - `tests/032-stabilize.sh`, 32 seconds, 16 of which are flat
    `sleep 4` guards.
  - `tests/031-watch-once.sh`, 21 seconds, 16 of which are flat sleeps.
  - `tests/024-phase1-exit.sh`, 19 seconds: a real 101-file C build,
    whose cost is mostly inherent.

  67 of the 75 shell tests already isolate their store with `mktemp` and
  a `HOME` override, so running them in parallel is safe today.

  Fixes, in order of impact:
  - split the single dune rule into one rule per test, so `dune build
    -j` can parallelize them (estimated 208 seconds down to 30 to 50
    seconds).
  - cut the 052 matrix to 1 or 2 representative variants, and move the
    full matrix to a nightly tier.
  - replace the flat sleeps with the bounded poll-until-condition idiom
    that already exists in the same files, and shrink `--watch-interval`
    alongside.

  This dovetails with the test-harness rewrite described under "Render
  each surface from one typed table".
- Docs into the manual site, considered at the docs sweep: the Typst
  manual is the one doc property that cannot lie (pp runs every
  example), so folding the other docs into that site would give one
  rendered home and let Typst generate what is now hand-maintained —
  for example a dependency DAG of plan items or features, rendered from
  data pp itself emits (`pp graph` already prints the cell-to-node
  graph). Two constraints decide the shape: the doc sources must stay
  greppable plain text, because 3 tests parse them (tests/072 reads
  SPEC.md's law headings, tests/067 its generated block, tests/074
  DESIGN.md's honest edges); and diagrams join as generated artifacts,
  never hand-drawn copies.
- Stretch, explicitly deferred, re-argue before building: map patterns
  in `match`; one-shot resumable effects; tail-call modulo cons; LSP;
  self-hosting.

Releases stay deliberately unplanned: no tags, no CHANGELOG (deleted,
since Conventional Commits make release notes reconstructible from git
log when a release is actually wanted; see RELEASING.md).

---

## Exit criteria (whole plan)

Checked once at the end; none of these becomes standing CI unless it
replaces a bigger mechanism it retired:

- zero `*_ref`/`*_hook` cells outside `backend.ml`; zero set-once-by-main
  refs outside the invocation record.
- `grep` finds one definition each of `force_deep`, the parse
  combinators, the string-coercion, `find_kv`, the tree walk, and one
  construction of the `"node-key"` skeleton, in the kernel.
- `reader_braces.ml` under about 1,500 lines; `tests/061b-qq-head-coverage.sh`
  deleted, in its own commit, after green, because nothing it checked
  can diverge any more.
- one flag table; `pp --help` and the parser cannot disagree.
- `Capability.t` and `Path.canonical` abstract; `dune build` is the
  proof that no module reaches around them.
- DESIGN.md names the tree-walker as the executable specification; the
  VM conforms via the differential suite.
- zero manual push/pop of dynamic-extent state: no `with_ref`, no
  `handler_save_stack`, no paired `push_`/`pop_trace_frame`;
  `dune-project` floor at OCaml 5.1 or above.
- `pp.kernel` lists no `unix`; the fuzzer runs at least one in-process
  property through the library.
- no file in the repo is unreachable from the build, test or docs graph;
  every directory named in the README; every doc states its purpose.
- the temporal-comment greps return zero hits in `src/`.
- `dune runtest`, `build-self.sh` and `build-lua.sh` green; the store-v1
  golden fixture stays byte-identical to its pre-plan state.

Net expectation: about 19,000 lines down to about 14,000 to 15,000,
fewer global names, strictly fewer mechanisms, one dependency floor
raised in exchange for an entire bug class, and every remaining line
either doing something or explaining something a reader needs.
