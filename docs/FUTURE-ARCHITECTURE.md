# pp FUTURE-ARCHITECTURE — rigor by construction, simplicity by subtraction

**Status: DRAFT. Part 0 runs now — it fixes live correctness holes and waits
for nothing. Parts I–III run after MASTER-PLAN Phase E.** Nothing in Parts
I–III gates any master-plan phase. For current reality see
[STATUS.md](STATUS.md); for the principles this plan applies see
[DESIGN.md](DESIGN.md) §1.

---

## 0. The criterion

**Rigor by construction, simplicity by subtraction.**

A ratchet (a drift test, a CI rule, a coverage check) is scar tissue: it
exists because the design still permits a mistake. The rigorous *and*
simple system is the one where the mistake is inexpressible — usually
because the thing that could drift no longer has a copy to drift from.
So this plan adds **no new kinds of anything**. Its one admission rule:

> **A change is accepted only if it net-deletes** — copies, mechanisms,
> global names, rules someone must remember, or tests that exist only to
> guard a seam. A change that adds a concept must retire at least two.

Where the plan does construct (Part II), the construction is itself a
deletion: an abstraction that makes a whole class of code — and the
prose and tests guarding against it — unnecessary.

One corollary the plan now states instead of assuming (it governs F6):

> **A copy is sanctioned only when its divergence is loud and the
> redundancy is itself the verification.** Two independent engines whose
> disagreement fails a differential suite are an oracle. Two helpers in
> two files whose disagreement fails silently are a trap. pp keeps
> exactly one copy of the first kind and zero of the second.

The plan has four parts, in order:

- **Part 0 — Correctness owed now.** Known holes fixed immediately;
  pristine includes *correct*, and correct doesn't wait for a refactor.
- **Part I — Subtraction.** Delete every copy and collapse the sprawl.
- **Part II — Construction.** The abstractions that pay for themselves,
  ordered so signatures freeze after the code they describe has settled.
- **Part III — The sweep.** Prod-readiness: no dead files, no dead docs,
  every directory a purpose, every comment self-contained.

Every stage ends green: `dune runtest`, the differential suite, and the
fuzzer. On-disk formats (cell-id strings, journal grammar, codec, store
layout) are **frozen throughout** — types and moves wrap representations,
never change them. Any stage that regenerates the store-v1 golden fixture
has violated this plan.

---

## Part 0 — Correctness owed now

### F0 — Three known holes, fixed this week, not after Phase E

Each is a handful of lines against current code. F5 later absorbs these
sites into abstract modules; the fixes do not wait for that.

1. **Constant-time MAC comparison.** `token.ml`'s `verify` compares the
   cluster-token HMAC with `<>` (`token.ml:205`) — a timing side channel
   on the one secret-bearing comparison in the system. Replace with a
   constant-time fold (length check, then XOR-accumulate over bytes;
   ~6 lines, no new dependency), and use it for any future MAC/secret
   equality.
2. **`CapRestrict` grants nothing under three checks.** `check_network`,
   `check_secret`, and `check_process` (`capabilities.ml:76–102`) all end
   in `| _ -> false`, silently swallowing `CapRestrict` — restricting a
   composed grant can *drop* network/secret/process authority rather than
   narrow it. Decide once, loudly: either `restrict` rejects non-fs
   capabilities with an error, or every check handles the wrapper.
   Whichever way, the decision lands with a test per channel.
3. **`check_type` passes unknown type names.** `evaluator.ml:55` —
   `| _ -> true (* unknown types pass for v1 *)` — means a typo'd
   annotation silently disables the check. Unknown type name becomes a
   hard error.

**Deletes:** two silent-authority failure modes and one silent-validation
failure mode, each currently guarded by nothing at all.

---

## Part I — Subtraction

### F1 — Collapse the global state (~30 names → 3)

**What exists:** ~19 forward-reference cells breaking compile-order
cycles (`primitives.ml:6–66,391–401`, `runtime.ml:151,163,173,485`,
`scheduler.ml:251`), each a `failwith "not initialized"` stub; plus 13
set-once-by-main invocation refs (`runtime.ml:236–433`) that are one
value written as thirteen.

**How:**
1. Create `backend.ml`, compiled immediately after `types.ml`: one record
   type holding the force/eval/apply/node-key/run-thunk/expand hooks, and
   one `let current : t option ref`. `Evaluator.init`/`Vm.init` each
   install a complete record in one assignment. Every former
   `!Primitives.eval_ref e env` call site becomes a field access; a
   single `Backend.get ()` raises once, with one message, if
   initialization was missed — instead of 19 stubs with 19 messages.
   The record carries the `Path.canonicalize ~realpath:Unix.realpath`
   partial application from F5, so "who may construct canonical paths"
   and "who installed the backend" are the same one question.
   **The §0 admission rule applies to this record's fields:** a new field
   must break a compile-order cycle; a field added for convenience is the
   19 refs growing back with better manners.
2. Create `type invocation = { source_roots; grants; argv; files;
   member_name; gc_keep_epochs; ... }` in `runtime.ml` with one ref.
   `main.ml` builds the record once after flag parsing. Callers that
   today read seven refs to assemble a value (`domains.ml:251–259` →
   `Gcroots.record`) read one field path.
3. Delete the 19 hook cells and the 13 invocation refs. The genuinely
   dynamic ambient state (`handler_stack`, `current_capabilities`,
   `config_stack`, `trace_stack`, sandbox stack, the registries) stays
   *ambient* — pp's dynamic-extent semantics require it, and fork-COW
   distribution (DESIGN Q9) depends on it — but its mechanism (paired
   push/pop over global refs) is replaced wholesale in F7. Part I leaves
   it untouched so F7 converts one settled shape, not a moving one.

**Deletes:** ~30 global names, 19 uninitialized-stub failure modes, and
the need to ever again answer "which refs must be installed before what"
by reading four files.

### F2 — Delete the literal copies (the blobref recipe)

`blobref.ml`'s own header documents the move: a helper needed below its
natural home gets extracted into a small early-compiled module, and the
original site becomes a re-export. Apply it five times:

| Copy | Sites | Fix |
|---|---|---|
| `force_deep` ×3 | `primitives.ml:182`, `domain_prims.ml:50`, `fenced.ml:122` — each with a comment admitting the duplication | Extract once (needs only `Types` + the F1 backend record); delete the three |
| Parse combinators (`>>=`/`expect_char`/`expect_lit`) ×5 | `codec.ml:167`, `store.ml:156`, `token.ml:140`, `transport.ml:390`, `remote.ml:93` | Export from `Codec` (already compiled first); delete four copies |
| `VString\|VKeyword\|VSymbol → string` coercion ×5–6 | `primitives.ml:986`, `domain_prims.ml:208–257`, `domains.ml:73`, `fenced.ml:47`, … | One `string_like : value -> string option` beside the value type; delete the rest |
| `find_kv` ×2 (already diverged: one forces, one doesn't) | `domains.ml:36`, `primitives.ml:992` | One function, forcing — the divergence is the argument for this row |
| Directory tree-walk ×5 | `runtime.ml:85` (delete), `island.ml:112` (copy), `store.ml:313` (hash), `domain_prims.ml:74` / `remote.ml:274` (collect) | One `fswalk.ml`: `walk : root:string -> (path -> Unix.stats -> unit) -> unit`; each caller keeps only its per-entry action |

Also in this stage, because they're one-file mechanical fixes to files
already open: the compiler's O(N²) emit (`compiler.ml:13–38` — list
append + `List.length` per opcode → growable buffer, offset as a
counter), and the `EDo`/`EModule` def-collection scaffolding
(`compiler.ml:227–323` vs `395–500`, ~70 duplicated lines → one helper),
and the VM's thrice-written arity-check/frame-build
(`vm.ml:258–271,286–299,380–397` → one `call_closure`).

**Deletes:** ~400 lines, five "fix it twice" traps, one quadratic cliff.

### F3 — One grammar, one lowering

**What exists:** `reader_braces.ml` (2,400 lines) contains a second,
hand-parallel parser for quasiquote mode. A′5 already collapsed the
precedence-climbing spine and the handler pairs into single
implementations parameterized by context; the block forms
(`try`/`collect`/`match`/`if` lowering, patterns, match arms) are still
written twice (`~1341–1522` vs `~2094–2260`). The CI rule `tests/061b`
(every `parse_head` arm ⊆ `parse_qq_head` ∪ exclusions) exists *because*
of this duplication.

**How:**
1. Extend the pattern A′1/A′5 proved out: each block form's parse builds
   one template (the `tmpl`/`spine` discipline), interpreted by the two
   existing context interpreters (AST vs quoted data) — exactly how the
   `$` heads already work via `interp_head_normal`/`interp_head_qq`.
2. Move the lowering functions (`lower_try_block`, `lower_collect_block`,
   match lowering) into `desugar.ml`, which states this as its charter
   ("every reader-level sugar whose output participates in LAW-20 hashing
   lives here"). `reader.ml` and `reader_braces.ml` both already call
   into it; after this they do so for everything.
3. Replace `looks_incomplete`'s substring-matching on exception text
   (`reader_braces.ml:2384–2396`) with a dedicated exception raised at
   the actual out-of-input sites; render the message from it. Reader
   error wording and REPL behavior decouple.
4. **Retire `tests/061b` — in its own commit, after the unification is
   green.** The lowerings feed LAW-20 hashing, so this stage is the one
   place the plan can silently change identity; the differential suite
   and the golden fixture are the gate, and the ratchet comes out only
   after they've passed on the unified parser — never in the same change
   that creates its last chance to fire. When a form parsed once exists
   in both contexts by construction, the rule 061b enforced has no
   violation left to catch. This is the plan's model outcome: the ratchet
   goes away *because* the duplication did.

**Deletes:** several hundred lines of parallel parser, one CI rule, one
stringly control-flow path. `reader_braces.ml` lands near ~1,400 lines:
lexer, spine, heads — and nothing written twice.

### F4 — One rendering per surface

Four places currently write the same list out by hand N times — the
exact failure mode A′ was created to end, in layers A′ didn't reach:

1. **CLI.** The flag list exists four times: 30 ref declarations
   (`main.ml:5–63`), 35 parse arms (`65–247`), 15 sequential dispatch
   blocks (`259–891`), 45 `--help` printfs (`189–234`). Replace with one
   typed table `{name; arity; doc; internal; handler}`; parse, dispatch,
   and `--help` iterate it. No Cmdliner — the table is plain OCaml and
   keeps the shell dep-free (DESIGN E6); expect a few flags with odd
   arities to need an escape-hatch row shape, and give them one honestly
   rather than four renderings. Promote `main`'s inline closures
   (`watch_loop`, `select_member_slice`, `build_all_desired`, …) to
   top-level functions over the F1 invocation record; `main ()` becomes
   read-table → build-invocation → dispatch.
2. **Primitives.** The single 850-line `let () = ...`
   (`primitives.ml:403–1250`) becomes `register_arith ()`,
   `register_lists ()`, `register_caps ()`, `register_domains ()`, …
   called from a ten-line body. Same registrations, named groups; the
   three helpers currently trapped inside the block become top-level.
3. **Lint.** Rules become one list of `(id, check, message)` walked
   uniformly (`lint.ml:103–197` currently hardcodes each as control flow
   with stale numbering — "1., 1a., 2., 6." with rule 5 in a different
   function). B4/B11/B12's planned rules then land as list entries.
4. **Tests.** `scripts/run-tests.sh` is ~50 copies of one six-line
   stanza (~85% of its ~460 lines); replace with a loop over `tests/*.sh`
   with the description read from each script's header line. Extract
   `tests/lib.sh` for the `assert`/`ok`/`bad` + `PP` normalization +
   `mktemp -d` preamble that 26+ scripts each re-declare. Adding a shell
   suite becomes: create the file. (The `.pp` differential suite already
   works this way — this makes the shell suites as cheap as the thing
   this project got right first.)

**Deletes:** three of four CLI renderings, ~400 harness lines, ~300 lines
of per-test boilerplate, the possibility of a flag documented but not
parsed (or parsed but not documented).

---

## Part II — Construction

Ordered deliberately: types first (F5), identity unified second (F6),
the extent mechanism third (F7), and the build boundary + `.mli` freeze
last (F8) — signatures are frozen only after F5–F7 have finished
reshaping what they describe.

### F5 — The two types that earn it

Both are subtraction wearing type clothing: each makes a catastrophic,
silent mistake *inexpressible*, and thereby retires the prose, review
vigilance, and negative tests that currently guard it. No other new
types in this stage. (No phantom-tagged hashes, no second AST, no
functors — each was weighed and fails the §0 criterion.)

1. **`Capability.t` becomes abstract.** The `capability` variant
   references nothing else in `types.ml`'s recursive group, so it
   extracts cleanly into an early-compiled module whose `.mli` exposes
   `mint` (called from exactly one CLI site), `restrict`, `compose`,
   `subseteq`, the per-channel `check_*` functions, and `hash` — and no
   constructors. LAW 22 (*unforgeable, root-minted; user code narrows
   and unions, never constructs*) stops being a discipline and becomes a
   fact about which functions return `t` — for OCaml-side code too,
   which today can fabricate `CapFilesystem {path="/"; mode=ReadWrite}`
   anywhere. The F0 `CapRestrict` decision moves inside this module,
   where the exhaustiveness that enforces it is confined. Rename
   `token.ml` → `cap_token.ml` while it's on the bench (it collides with
   the lexing concept).
2. **`Path.canonical = private string`.** DESIGN §2.1's law —
   canonicalized *once* so the D8 bug class cannot reappear — currently
   holds by discipline; any new call site can hand a raw symlinked path
   to an authority check. Give `canonicalize` the only constructor;
   `Paths.under`, `Cell.File`, capability checks, and sandbox/loader
   containment take `canonical`. `private` (not abstract) keeps reads,
   printing, and hashing zero-cost. **The kernel/syscall tension,
   decided now:** canonicalization is `realpath` — a syscall — but
   `path.ml` must live in the syscall-free kernel (F8). So the kernel
   signature is `val canonicalize : realpath:(string -> string) ->
   string -> canonical`: the resolver is injected, the kernel stays
   pure, and the sole partial application (`~realpath:Unix.realpath`)
   lives in the F1 backend record — one blessed construction site, held
   by the same mechanism that holds every other backend hook.

### F6 — One identity, two engines

**What exists:** the package synopsis promises "two back ends (a
tree-walking interpreter and a bytecode VM) that must produce identical
output." Under §0's corollary this copy is *sanctioned*: the engines are
independent by design, and the differential suite makes their divergence
loud — the redundancy is the verification. This is the settled industry
lesson, arrived at from both directions: V8 deleted its second full
implementation (full-codegen/Crankshaft) precisely because hand-parallel
implementations of one semantics drift; WebAssembly ships a small
reference interpreter (in OCaml, as it happens) as the executable
specification, with a conformance suite production engines must pass.
pp already has the WebAssembly shape. This stage finishes it.

What the sanction covers is **execution**. It does not cover
**identity** — and today the LAW-20 node-key construction (the
`["node-key"; hash_expr e]` / `["fv"; name; hv]` skeleton plus the
capability/sealed free-var ban) is written twice (`evaluator.ml:411`,
`vm.ml:639`), with a comment demanding the formats stay byte-identical.
An identity divergence is not an execution divergence: it wouldn't fail
a differential assertion, it would silently split the store — the same
node keying differently per engine. Identity must exist once; then the
engines can only disagree about *how* to compute, never about *what a
thing is*, and every remaining possible disagreement is a loud
differential failure.

**How:**
1. **Extract the key skeleton into the kernel.** One function beside the
   hasher: given the expr hash and the free variables (name → forced
   value), build the key and enforce the authority ban. `node_key_of`
   and `vm_node_key` become ~10-line adapters supplying only what
   genuinely differs — free-var enumeration (env lookup vs the
   compiler's frame/global descriptors) and each engine's force. "Must
   stay byte-identical" stops being a comment and becomes the absence of
   a second implementation. (Closure-valued free vars still hash per
   backend, as today — that residual is execution strategy, and each
   key remains sound; the *format* can no longer drift.)
2. **The rebuilder becomes one findable file.** DESIGN §2.2 presents
   "THE REBUILDER (one impl)" as a page of pseudocode; its
   implementation is currently smeared across `evaluator.ml`
   (`force_node`, `run_node_body`, `cell_authorized_for`), `store.ml`
   (`hit`), and `runtime.ml` (trace frames). Move — don't rewrite —
   into `node.ml`, with the key skeleton and both adapters in one place.
   `tests/010–024` pin the move.
3. **Declare which engine is normative.** One sentence in DESIGN: the
   tree-walker is the executable specification; the VM conforms. When
   they disagree, the differential suite has found a VM bug unless the
   spec is shown wrong. (Today that judgment is re-made ad hoc per
   incident.)
4. **What is deliberately not done:** deleting either engine (the
   redundancy is the oracle — see the corollary), and generating one
   engine from the other (a generator is a third implementation of the
   semantics; fails §0).

**Deletes:** the second key implementation, the byte-identical-by-
discipline rule and the review vigilance behind it, and the standing
ambiguity over which engine to trust when they disagree.

### F7 — Dynamic extent by construction (OCaml 5 effect handlers)

**What exists:** pp's dynamic-extent semantics are implemented as four
parallel global stacks in `runtime.ml` (`handler_stack`,
`current_capabilities`, `config_stack`, `trace_stack` — plus
`sandbox_stack`, documented as "one slot per active node force,
*parallel to trace_stack*"), maintained by hand-rolled dynamic-wind at
every extent boundary: `with_ref` in the evaluator, a shadow
`handler_save_stack` in the VM whose `POP_HANDLER` must "restore the
pre-PUSH handler stack exactly, not pop-one (D9)" — a comment that is
the fossil of exactly the bug this stage makes inexpressible —
`pop_trace_frame`'s mirrored dual-pop with sandbox cleanup "on every
exit path," and both engines' `init` resetting the refs to `[]`. The
discipline is correct today because each historical unbalancing got a
pin. The mistake class — an extent exited without restoring, restored
out of order, or restored on the normal path but not the raising one —
remains expressible at every one of these sites and is guarded by
review.

This is what OCaml 5 effect handlers are natively: dynamic extent held
by the language runtime instead of by refs the program must wind and
unwind correctly. `try_with` installs a frame on the stack; leaving it —
normal return, pp condition, OCaml exception — unwinds it, by
construction. This is the plan's one construction that replaces a
*mechanism* rather than a copy, and it passes the admission rule several
times over (see Deletes).

**How:**
1. One kernel module declares the effects — one per ambient question the
   runtime answers: handler lookup by name, ambient capability set,
   config lookup, trace-read recording, sandbox resolution. (`Effect` is
   stdlib; the declarations are pure and kernel-safe.)
2. Extent constructs install handlers, in both engines. `with-handler` /
   `with-caps` / `with-config` become `try_with` around the body; in the
   VM, the `WITH_HANDLER` arm runs the body by reentering `run` under
   `try_with` — deleting `handler_save_stack` and `POP_HANDLER` outright
   (OCaml recursion depth = extent nesting depth, the same depth the
   save-stack already tracked by hand). A node force installs one frame
   owning its trace list *and* its sandbox slot; sandbox teardown is
   that handler's finalizer — "every exit path" becomes the only path.
   The parallel-stacks problem disappears because there is one frame per
   extent, not four stacks kept in step.
3. Trace recording composes instead of iterating a global: each frame's
   handler appends to its own list and re-performs outward, so "recorded
   into all active frames" (the rule `record_read` implements today by
   walking `!trace_stack`) falls out of deep-handler forwarding.
4. **Fork-COW (Q9) is preserved by the same mechanism, not despite it.**
   Handler frames live on the OCaml stack; `Unix.fork` copies the stack;
   the child continues under byte-identical extents — the exact property
   Q9 bought with global refs, now guaranteed by the runtime instead of
   maintained by discipline. (Q9's rejection of *domains* — "the
   interpreter is saturated with global mutable state" — is untouched;
   this stage reduces the saturation it complained about.)
5. **Identity is untouched.** LAW 20 keys never read ambient state (both
   key functions state this; F6 makes it one statement); node capture
   (LAW 23b) is unchanged in meaning — creation reads the ambient set
   once and stores it, force reinstalls it as the answer to the
   capability effect, exactly what `with_ref current_capabilities
   t.node_caps` does today. The differential suite and the golden
   fixture gate the conversion.
6. **The cost, stated plainly:** `(ocaml (>= 4.14))` becomes
   `(>= 5.1)` — the one dependency-floor change in this plan (the
   development switch is already 5.4). If some deployment target truly
   cannot move, this stage is severable; nothing else in the plan
   depends on it. But the default is to move: the floor buys deleting an
   entire expressible-mistake class.

**Deletes:** `with_ref`, `handler_save_stack` + `POP_HANDLER`'s
exact-restore discipline (D9's scar), `pop_trace_frame`'s mirrored
dual-pop, the two engine-init resets, the four-parallel-stacks-in-sync
rule, and the global refs themselves — and with them the whole
expressible class of unbalanced dynamic extent, which no test today can
pin exhaustively because every new extent site re-opens it.

### F8 — One boundary, held by the compiler

Last in Part II by design: `.mli`s freeze surfaces, so they are written
against the post-F5–F7 shape, not the current one.

1. **One library.** `src/dune`'s flat 47-module executable becomes
   library `pp` + a thin `main` executable. One split, not seven: the
   only structural rule worth a build boundary is **the kernel is pure**
   — the identity/authority/naming/codec modules (`types`' successors,
   `hasher`, `cell`, `capability`, `path`, `codec`, `surface_tables`,
   `cap_token`, the F7 effect declarations) live in a `pp.kernel`
   sub-library that lists no `unix`. That single boundary makes E6's
   "keep the oracle auditable" a build fact, and lets tests and the
   fuzzer link the reader/printer/evaluator in-process — which is what
   MASTER-PLAN A″2's derived generators actually need (today's fuzzer
   can only shell out to the binary).
2. **`.mli` for the remaining wide-open modules** — `evaluator`,
   `compiler`, `vm`, `reader`, `reader_braces`, `macro`, and `types`'
   successors — completing what A′4 started for the kernel. Each is the
   inferred signature trimmed to what its callers use (F1–F7 will have
   shrunk that surface first, which is why this stage runs last in
   Part II).
3. **Explain or drop `-no-strict-sequence`** (`src/dune:9`,
   `tools/dune:7`) — the only unexplained flag in a repo where every
   other build choice documents itself.

---

## Part III — The sweep (prod-readiness)

Run after Parts I–II so it sweeps the final shape, not a moving target.

### F9 — No dead anything

1. **Files.** Delete the stale build residue in `src/` (`*.cmi`/`*.cmo`
   from a pre-dune compile — including `cache.*` and `bytecode.*`, whose
   `.ml` sources no longer even exist; they are gitignored but sitting
   in every checkout's listing). Then inventory `src/`, `scripts/`,
   `tools/`, `demo/`, `examples/`: every file is either reachable from
   the build/test graph or deleted. The check is a one-time audit, not
   new CI.
2. **Directories.** Every top-level directory gets one line in the
   README's layout section stating its purpose; a directory that can't
   fill in that line honestly gets merged or deleted.
3. **Docs.** Each file in `docs/` opens by stating what question it
   answers and when it was last true (the good ones — DESIGN, SPEC,
   STATUS — already do). Superseded plan documents are deleted, not
   archived: git history is the archive (house precedent:
   PRAGMATIC-SYNTAX/PATTERNS/CONVENTIONS were already consolidated away;
   finish the job for anything Phase E leaves behind, and re-point
   ARCHITECTURE.md's file table and pipeline diagram at the post-F8
   tree). Delivery *narrative* (what landed when, in which stage, versus
   what the contract asked) migrates out of DESIGN.md into
   STATUS/CHANGELOG where it belongs; DESIGN keeps the timeless
   rationale.

### F10 — Comments say what's true, not what task produced them

The codebase's comment density is a strength; its failure mode is
comments written to the *plan* instead of to the *reader*: "M5 stage B
update", "the A3 fix", "PLAN-m4-cells.md's Vault/SOPS line", "so
tests/011/013/017 are byte-for-byte unaffected" — coordinates into
documents a future maintainer isn't reading, standing where the
invariant should be.

**The rule:** a comment must be understandable with no document open
beside it. After that, one trailing pointer is welcome — but only to
*stable* vocabulary: SPEC laws, GLOSSARY terms, DESIGN's Q1–Q12 and
D-list (those are permanent, indexed names). Milestone letters, plan
phases, stage narratives, "this commit", and test numbers as
justification are temporal scaffolding: they were true while the work
happened and are noise after it merges.

Before (types.ml, `node_caps`):

> *Node capture (DESIGN Q11's promise): the ambient capability set at
> THIS process's creation … populated unconditionally at both
> construction sites … Collapses to the process's --grant set when
> with-caps is unused … so tests/011/013/017 are byte-for-byte
> unaffected.*

After:

> *The ambient capability set captured when this node value was created.
> `force_node` uses this — never the live ambient — for both the hit
> gate and the miss recompute: a node's authority is fixed at creation,
> exactly as a closure's environment is (SPEC LAW 23b).*

**The pass:** grep for the temporal patterns (`M[0-9]`, `[A-F]″?′?[0-9]`,
`stage [A-C]`, `PLAN-`, `tests/[0-9]` inside `.ml` comments, "this
commit", "the contract"); at each hit, rewrite the comment to state the
invariant in place, keeping any SPEC/Q/D pointer that still helps.
Delete outright the comments that only justified a diff to its reviewer
("no change to X was needed", "unchanged from the previous approach",
"the same function the serial arm calls, so there is no second code
path" — if that matters, it's an assertion or a test, not a comment).
Fix the known-stale headers while there: `evaluator.ml:1` still reads
"lazy, call-by-need evaluator" — retired by DESIGN Q1 two phases ago.

This is a one-time editorial pass plus a review norm — deliberately not
a lint rule. Rigor about prose comes from the norm; a comment-linter
would be one more mechanism, which §0 forbids.

---

## Exit criteria (whole plan)

Checked once at the end; none becomes standing CI unless it replaces a
bigger mechanism it retired:

- MAC comparison constant-time; `CapRestrict` behavior decided and
  tested per channel; unknown type names a hard error. (F0 — checked
  the week it lands, not at the end.)
- Zero `*_ref`/`*_hook` cells outside `backend.ml`; zero
  set-once-by-main refs outside the invocation record.
- `grep` finds one definition each of `force_deep`, the parse
  combinators, the string-coercion, `find_kv`, the tree walk — and one
  construction of the `"node-key"` skeleton, in the kernel.
- `reader_braces.ml` under ~1,500 lines; `tests/061b` deleted (in its
  own commit, after green) because nothing it checked can diverge
  anymore.
- One flag table; `pp --help` and the parser cannot disagree.
- `Capability.t` and `Path.canonical` abstract; `dune build` is the
  proof no module reaches around them.
- DESIGN names the tree-walker as the executable specification; the VM
  conforms via the differential suite.
- Zero manual push/pop of dynamic-extent state: no `with_ref`, no
  `handler_save_stack`, no paired `push_/pop_trace_frame` — extent is
  held by effect handlers; `dune-project` floor at OCaml ≥ 5.1.
- `pp.kernel` lists no `unix`; the fuzzer runs at least one in-process
  property through the library.
- No file in the repo is unreachable from the build/test/docs graph;
  every directory named in the README; every doc states its purpose.
- The temporal-comment greps return zero hits in `src/`.
- `dune runtest`, `build-self.sh`, `build-lua.sh` green; store-v1 golden
  fixture byte-identical to its pre-plan state.

Net expectation: ~18k → ~14–15k lines, fewer global names, strictly
fewer mechanisms (effects replace four stacks and their winding code;
one CI rule *retired*), one dependency floor raised in exchange for an
entire bug class — and every remaining line either does something or
explains something a reader needs.
