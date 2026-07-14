# pp Surface — Master Implementation Plan (v2)

The implementation plan for the settled surface in [SYNTAX.md](SYNTAX.md).
This v2 plan supersedes the original ergonomics plan and its companion
analysis docs (`PRAGMATIC-SYNTAX.md`, `PATTERNS.md`, `CONVENTIONS.md`),
which were consolidated into SYNTAX.md after a two-round design review.
Rejected features are recorded in [DESIGN.md](DESIGN.md) §6 — do not
re-propose them here.

**Ordering principle: defects, then one source of truth, then kernel
verification, then syntax.** Phase A fixes defects — determinism, backend
agreement, macro/surface coherence, SPEC honesty. Phase A′ hardens the
architecture so the defect *classes* can't recur: every closed surface set
derived from one typed OCaml table, module seams made explicit. Phase A″
verifies the trust kernel itself — hash injectivity, the capability
algebra, executable SPEC laws, crash safety — with every obligation
attached to a compiler or CI ratchet (DESIGN §1 principle 8), never to a
checklist. Phase B settles the surface by *removing and migrating*; only
then does Phase C add sugar. **Nothing in B or C ships while an A or A′
item is open, or before A″'s kernel properties and ratchet mechanisms are
in place** (see A″'s gating note for the tranche rule).

> **Status pinning.** Status below is as of branch
> `pragmatic-suffix-conventions` @ `4312104` (A1–A7 + A′1 at `5a7d718`;
> A′2/A′3/A′4 + handler-pair slice of A′5 at `aca3ddf`; the A′5 precedence-
> climbing-spine dedup — `reader_braces.ml`'s two mirror spines collapsed into
> one `climb_*` parameterized by a `spine` ops record with `normal_spine`/
> `qq_spine` builders and shared `parse_arglist` — at `4312104`), plus the A″1
> injective-hash-encoding fix at `6ff2391`: `hash_concat` (`types.ml`) length-
> frames every part (`<len>:<bytes>`), the two delimiter-free `hash_pattern`
> joins and the `env_extend_hash`/`hash_bindings_flat` env hashers reroute
> through it, and `store.ml`'s `env_observed_hash` gains distinct
> `env-present`/`env-absent` tags (a value `"absent"` used to collide with an
> unset var). Hash-affecting: the `store-v1` golden fixture was regenerated (the
> receipt); near-misses pinned by `tests/070`.
>
> A″2 lands in *this* commit: `src/kernel_props.ml` (derived generators + the
> three kernel properties, run via `pp --check-kernel-props`, gated by
> `tests/071`; module added to `src/dune`, flag to `main.ml`, suite hook in
> `scripts/run-tests.sh`). The injectivity property caught a residual
> A″1-class collision — `hash_expr EIsland` conflated `None` with `Some ""` —
> now framed (`types.ml`; island node keys change, but no golden or test
> depends on an island hash, verified against `tests/035`/`037`). The printer
> round-trip property caught two `printer_braces` `pp fmt` bugs: tagged patterns
> printed `[:tag …]` (reader wants `(:tag …)`) and spread-only list patterns
> printed with a leading comma `[, …r]` — both fixed. `printer_braces`/`main`/
> `dune` edits are not hash-affecting; the whole-tree fmt round-trip (`tests/055`,
> 69 files) is green, so no fixture regeneration. Any edit to a status entry must
> update this pin. A status table that doesn't name its ref is a defect (this bit
> a reviewer once already).
>
> A″3–A″6 land in *this* change (working tree, atop `5837b2c`), completing Phase
> A″: (A″6) the capability generator + four algebra properties in
> `src/kernel_props.ml`, gated by `tests/075`; (A″4) the `Store.atomic_write`
> crash oracle (`PP_CRASH_AT`) + sweep harness `tests/073`; (A″3) the law-linkage
> gate `tests/072` + tranche-1 `# pins:` markers across a dozen existing tests +
> the SPEC preamble note; (A″5) the adversarial fixtures under
> `tests/fixtures/adversarial/`, DESIGN §4 edges E10/E11, and the table-keyed
> rule `tests/074`. A″5 caught and fixed a live defect — `$glob` lowered to a
> nonexistent `list-dir`; the `Surface_tables.tmpl` DSL gained a `Perform` node
> so `$glob` lowers to `(perform tree-observe …)` (both readers + qq), which
> regenerated the SPEC surface-table block (§B.8; A′2 drift test green) — the
> only hash-affecting edit, and no `$glob` user existed to re-key. All four new
> gates wired into `scripts/run-tests.sh`.
>
> **Phase B (B1–B12) lands in *this* change (working tree, atop `9b30279`),
> completing the surface settlement.** Removals: cell literals (B1), `cond {}`
> (B6), postfix `?` (B7), `@` attributes (B8) — all near-zero tree impact.
> Migrations/additions: map spread `{ ...m, k -> v }` (B3, hash-preserving, +
> `map-merge` primitive), `collect` as a pipeline function (B2), `$config` head
> (B5, + `Config` tmpl node, DESIGN §4 E12), `handlers: { … }` clause (B9,
> surface only — value-based `EWithHandler` deferred), `run-dep` → `run-dep!`
> (B10, hash-affecting rename). Lints: observation-exclusivity (B4, a
> pre-lowering token scan off `Surface_tables.observation_primitives`),
> dot-identifier (B11), tagged-value convention (B12). Hash-affecting edits: B10
> (effect rename) and the regenerated SPEC §B.8 block (B5/B9 table rows) — no
> other. New gates `tests/076`–`080` wired into `scripts/run-tests.sh`; the
> whole-tree fmt round-trip (`tests/055`) and both backends stay green. The one
> regression caught in progress — the removed `{ m \| k -> v }` update form was
> still used at three stdlib sites and one manual example — was migrated to
> spread (hash-preserving via the spread-first `map-insert` lowering).
>
> **Phase C (C1–C4) lands in *this* change (working tree, atop `b4cac85`),
> adding the missing sugar.** f-strings (C1, `f"…{expr}…"` → `string-append`/
> new `->string`), call spread (C2, `f(a, ...rest, b)` → new `apply` primitive),
> `match` guards (C3, `pat if cond =>`), and the sexpr `match` surface (C4). Only
> C3 touches the trust kernel — `EMatch` arms gained an `expr option` guard slot,
> encoded so a `None` guard hashes/quotes IDENTICALLY to the pre-C3 2-tuple, so
> **no existing match is re-keyed** (verified by `tests/055` at 69 files + the
> `tests/071` injectivity/quote-RT/print-RT properties, both green). f-strings and
> call spread are one-way desugars (like `|>`), so they round-trip hash-preserved
> with no new AST node. C5 (map patterns) is deferred as a documented scoping
> decision (stretch, underspecified surface). The C-phase fuzzer additions
> (`tools/fuzz.ml` now generates guarded `match`, `apply`, `->string`) surfaced
> and fixed **two pre-existing `match` VM/tree-walker divergences** — car on a
> non-pair scalar, and a nested-scrutinee temp-name collision — neither hash-
> affecting (compiler-lowering fixes + one added unshadowable alias `pair?`). New
> gates `tests/081`–`084` wired into `scripts/run-tests.sh`; 1500+ fuzz programs
> across five seeds pass with 0 mismatches (2 readers × 2 backends).

---

## Quality gates (every item, non-negotiable)

1. **Differential:** both backends produce the same result and the same
   error text for every touched form.
2. **Round-trip:** `pp fmt --to-braces | pp fmt --to-sexpr` preserves the
   LAW-20 hash for generated and hand-written examples.
3. **Quasiquote parity:** the form parses identically inside
   `quasiquote {}` (same lowering, same collection defaults) or is added to
   SPEC B.7's exclusion list. Fuzzer round-trips through
   `quasiquote { unquote(...) }`.
4. **Fuzzer** generates the form; invariants hold.
5. **`dune runtest` green**; no regressions.
6. **Manual:** at least one executed example uses the form.

---

## Phase A — Bulletproof the core (defects)

All items are fixes to code already on this branch, or SPEC amendments that
make existing behavior honest. No new surface.

| # | Item | Detail | Status |
|---|------|--------|--------|
| A1 | **Deterministic `try` lowering** | `try_counter` (`reader_braces.ml:319`) is a global ref never reset per parse, so `__try_N` temp names — and therefore LAW-20 hashes — depend on what was parsed earlier in the process. Derive temp names from position (or reset per top-level form), and add a test that parses the same file twice in different orders and asserts identical `hash_expr`. | done |
| A2 | **Quasiquote/list divergence** | Inside `quasiquote {}`, `[...]` still lowers to `vector` while ordinary code lowers to `list` — a macro template builds a different value than the code it generates. Align the quasiquote path with L9 (list). | done — `parse_qq_primary`'s `[...]` arm now builds a `qq_chain` cons list (VNil-terminated), matching sexpr `parse_qq_list` and L9; template value now `=` the literal's value on both backends. Pinned by `tests/060-qq-list-parity.sh`. |
| A3 | **Quasiquote coverage of new sugar** | None of `try`/`match`/`$KIND`/`m[k]`/spread parse inside `quasiquote {}`. Implement each (or document as a B.7 exclusion with rationale). Add the CI rule: every new `parse_head` arm appears in `parse_qq_head` or in B.7. For table-driven forms (`$` heads, `with` clauses, grant sugar) parity comes free from A′1/A′5; this item covers the block forms (`try`/`match`/spread/`m[k]`). | done — `try`/`match`/`m[k]`/list-spread now parse inside `quasiquote{}`, each building the *same* data shape as the ordinary form (mirroring `lower_try_block`, `quote_pattern`/`quote_to_value`'s `EMatch`, `parse_postfix`'s accessor choice, `build_spread_list`). `value_to_expr` gained the previously-missing `EMatch` inverse (new `value_to_pattern`) so a `quasiquote{match}` template reconstructs a real `EMatch` after macro expansion instead of a bare `(match …)` application. A latent `parse_qq_postfix` bug (a next-line `(`/`[` swallowed as postfix) was fixed in passing (`~nl:true`→`~nl:false`). Value-parity pinned on both backends by `tests/061-qq-sugar-coverage.sh`. The CI rule (every normal `parse_head` arm ⊆ `parse_qq_head` ∪ explicit exclusions) is `tests/061b-qq-head-coverage.sh`; documented exclusions: `cond`/`collect`/`fenced`/`with`/`vec`. `$` heads remain deferred to A′1 as planned. A fuzzer-integrated qq-parity gate (Phase A exit) is still outstanding. |
| A4 | **`else`-newline misparse** | `parse_if` doesn't `skip_nl` before checking `else`, so `}\nelse {` silently parses as no-else + stray symbol + map literal. Fix in the **parser** (accept newline before `else`); `pp fmt` normalizes to `} else {`. | done — `parse_if` now `skip_nl`s before checking for `else`, consuming the newline(s) only when `else` actually follows (position save/restore), so a trailing newline still terminates an else-less `if` instead of being swallowed. Same fix applied to the quasiquote `if` arm for parity. Pinned on both backends by `tests/062-else-newline.sh`, including the else-less-`if`-followed-by-a-statement case that proves the newline is not wrongly consumed. |
| A5 | **Match lowering shadowing hazard** | The compiler lowers `match` via `EApply(ESymbol "car"/"="/"nil?"/"not"/...)` — user code shadowing those names diverges the VM from the tree-walker (which matches structurally). Route the lowering through unshadowable internal primitives; add a fuzz case that shadows `car` inside a match arm. | done — the `match` lowering (`compiler.ml` `EMatch`) now references `car`/`cdr`/`=`/`nil?`/`not`/`error` via NUL-prefixed unshadowable aliases registered in `primitives.ml` from the same builtin values (mirrors `dead_slot`; no pp identifier can contain a NUL). User code shadowing those names can no longer divert the VM's match machinery, so it stays in agreement with the tree-walker (which matches structurally via `Types.match_pattern`). Pinned on both backends by `tests/063-match-shadow.sh`, which shadows all six primitives and checks structural results plus a shadowed-`error` fall-through. Implemented as a differential test rather than a fuzzer case; the fuzzer-integrated shadow case (Phase A exit) is still outstanding. |
| A6 | **`$KIND` takes expressions** | `$file`/`$glob`/`$secret` currently accept string literals only; real code computes paths (`demo/deploy.pp:68`). Accept arbitrary expressions in all `$` heads (incl. `$env` name + default). Without this the exclusivity lint (B4) is impossible. Implemented *via* A′1: table-driven heads parse their arguments as ordinary expression lists uniformly, so per-head literal restrictions cannot exist. | done — landed *via* A′1. Every `$` head now parses `parse_args` (an ordinary expression list) and lowers through the table's template; the per-head `TString`-only arms are gone, so a computed name/path/default works. Arity is checked from the table (`min_args`/`max_args`). Differential-tested on both backends by `tests/066-dollar-heads.sh` (computed `$env` name, computed default, arity error, qq parity). |
| A7 | **SPEC honesty amendments** | (i) L9 re-pointed at `list`, marked **revised, not sugar** — the bracket change was hash-affecting and the golden-store fix commit is the receipt; add a `pp check` sweep for `vector-get`/`vector-length` on bracket literals. (ii) B.1 gains the `->` glue sentence with the `string->number` example. (iii) LAW 4 gains the documented `try {}` exception: `<-` bindings are sequential, rebinding shadows; pin with a differential test that rebinds a name twice. | done — (i) SPEC L9 now reads `(list …)` with a **revision (not sugar)** note spelling out the hash-affecting nature and the golden-store regeneration as the receipt; the sweep landed in `pp lint` (the static-source checker; `--check` is the runtime determinism audit) flagging `vector-get`/`vector-length` on a bracket literal, pinned by `tests/064-l9-vector-sweep.sh` (incl. a no-false-positive-on-`vector(…)` case). (ii) SPEC §B.1's whitespace rule gained the `->`/`string->number` glue paragraph. (iii) SPEC LAW 4 gained the `try {}` sequential-`<-`/rebind-shadows exception, pinned by `tests/065-try-rebind-shadow.sh` (rebinds twice, short-circuit case, and the contrast that an ordinary letrec* block still rejects a double def) on both backends. |
| A8 | **`collect{}` block bug** | The implemented statement-partitioning lowering contradicts its own motivating example (which would crash). Resolved by B2 (conversion to a function) — no fix to the block form. | superseded by B2 |

**Exit:** all of A1–A7 closed; a same-source-twice hash-determinism test,
a shadowed-`car` match fuzz case, and a quasiquote-parity fuzz gate exist
and run in CI.

---

## Phase A′ — One source of truth (architecture hardening)

Phase A fixes the defects; A′ removes the *conditions* that produced them.
The recurring failure mode this branch exposed is the same list written out
by hand in N places — the `$` heads in the reader, the quasiquote grammar,
the lint whitelist, the fuzzer, and SPEC; the grant descriptors in the
reader and the docs; two readers duplicating sub-grammars. Hand-maintained
copies drift; drift was every one of D4/D5/D6/D9. The fix is the OCaml
discipline the codebase already half-has: **each closed set is one typed
value in one module, and everything else is derived from it — with variant
exhaustiveness making "forgot to decide" a compile error instead of a
review comment.**

Ground truth found while planning (verified at `2f817c8`):
- `Cell.t` (`src/cell.ml:25`) already IS the closed variant of cell kinds —
  14 constructors. The runtime has the single source of truth; the surface
  layers just never consume it.
- `needs` is **already value-open**: the lowering's fallback (`| e -> e`,
  `reader_braces.ml:781`) passes any non-sugar expression through to
  `cap-compose`. The "closed grant vocabulary" is three sugar heads, not a
  semantic limit. What's missing is documentation, tests, and table-driving
  the sugar.
- `src/` is 17,099 lines across 30+ modules with **zero `.mli` files** —
  no boundary in the codebase is compiler-enforced.

| # | Item | Detail | Status |
|---|------|--------|--------|
| A′1 | **`surface_tables.ml` — the closed sets as data** | One module holding the typed tables every other layer derives from: (i) **observation heads** — `{head; cell_kind; lowers_to; arity; qq_legal; doc}`, produced by an *exhaustive* function over `Cell.t` returning `` `Head spec `` or `` `RuntimeRecorded reason `` so every cell kind carries an explicit surface decision (adding a Cell constructor without deciding its surface story becomes a compile error; the pass will force currently-undecided kinds — e.g. `Stat`, read today via `file-exists?`, must either join as `$stat` or be a documented lint whitelist entry); (ii) **`with` clauses** — `caps`/`config`/`handlers` → wrapper constructor; (iii) **grant descriptor sugar** — `fs.read`/`fs.write`/`fs.rw` → restrict mode. Consumers: both readers (normal *and* quasiquote paths), `lint.ml` whitelists, the fuzzer's generators, and error messages ("unknown observation `$foo`; known heads: …" listed from the table). Head arguments parse as ordinary expression lists uniformly — subsumes A6. | done (core) — `src/surface_tables.ml` holds all three tables plus `surface_decision : Cell.t -> surface_story`, an **exhaustive** match over every `Cell.t` constructor (compiled under warnings-as-errors, so a new cell kind without a surface decision fails the build — the ratchet). The head lowering is a small `tmpl` DSL so the shape lives once and both readers interpret it (normal → AST via `interp_head_normal`; quasiquote → quoted data via `interp_head_qq`), closing A3's deferred `$`-head qq-parity item. Consumers rewired to source strings from the table: both readers' `$` heads, the `with{}`-clause keywords, the grant-descriptor sugar, and the unknown-head error (`known_heads_message`, now listing heads from the table). The `caps`/`config`/`handler`/`fs.read`/`$`-head strings now appear only in `surface_tables.ml` (the cell-literal `file:`/`env:`/`tree:` set is B1's separate removal target; `config`-the-special-form is a distinct set). **Deferred to their natural rows:** the fuzzer's generators sourcing from the table (fuzzer gate, Phase A exit), `lint.ml`'s observation-exclusivity whitelist (B4), and the grep-based single-`.ml` CI check + SPEC-rendered table block (A′2). The `with_clauses` table reflects the pre-B9 grammar (`handler` singular); B9 flips it. Pinned by `tests/066-dollar-heads.sh`. |
| A′2 | **SPEC drift test** | The tables render to a generated block (between markers) in the SPEC appendix; a CI test regenerates and diffs. No closed set is ever hand-listed in SPEC again — the doc-sync failure mode (D10) becomes a red build, not a stale paragraph. | done — `Surface_tables.render_spec_tables` emits the three closed tables (heads/`with`-clauses/grant sugar) as markdown; `pp --dump-surface-tables` prints it; SPEC §B.8 carries it verbatim between `<!-- BEGIN/END GENERATED surface-tables -->` markers. `tests/067-surface-tables-drift.sh` regenerates and diffs (proven red on a one-word table edit) AND grep-checks that the grant descriptors (`fs.read`/`fs.write`/`fs.rw`) live in exactly one `.ml` — the single-source backstop the exit criterion names. The hand-listed grant enumeration in SPEC L35 was replaced by a pointer to §B.8. (Head/`caps:`/`config:`/`handler` strings overlap the cell-literal B1 path and the `config` reserved word, so the grep is scoped to the grant set, which has no other legitimate use; the drift test covers all three tables' content.) `docs/SPEC.md` added as a `runtest` dep so the test resolves under the dune sandbox. |
| A′3 | **`needs` value-openness made normative** | Document in SYNTAX.md §5 and SPEC: `needs` accepts any expression evaluating to a capability; the dotted descriptors are table-driven sugar (A′1). Named grants are ordinary bindings — `let k8s-prod = cap-compose(net("k8s.prod.internal"), process)` … `node deploy() needs k8s-prod { … }`. Add differential tests (both backends) for named/composed grants and for the sugar. The capability *kind* set stays closed — see DESIGN.md §1 principle 7 for why it cannot "run out". | done — SYNTAX.md §5 already carried the value-open normative text with the `k8s-prod` example; SPEC L35 prose now states it normatively too (and points its grant enumeration at §B.8). `tests/068-needs-value-open.sh` differential-tests all three spellings — descriptor sugar, a named `let ro-grant = cap-restrict(…)`, and a composed `cap-compose(…)` — reading a granted file identically on both backends, plus the negative that a named grant genuinely NARROWS (the ⊆ gate, not the reader, denies a read outside its scope, identically on both backends). |
| A′4 | **Compiler-enforced module seams** | Add `.mli` interfaces to the soundness kernel first — `cell`, `capabilities`, `hasher`, `store`, `runtime` — exposing only the intended API (e.g. `Runtime.record_read` stays; its internals don't). Then the surface layer: `surface_tables`, `desugar`. Exit test: `dune build` fails if any module reaches around a seam. This is the down-payment on "clear abstraction boundaries"; further `.mli` coverage proceeds opportunistically. | done — seven `.mli` seams landed: the soundness kernel (`cell`, `hasher`, `capabilities`, `runtime`, `store`) and the surface layer (`surface_tables`, `desugar`). Each is the compiler-inferred interface trimmed to the intended API: e.g. `runtime.mli` keeps the coordination surface (`record_read`, trace frames, `observe_*`, sandbox/loader entries) but hides the internals behind them (`config_cell_id`/`handler_cell_id`/`config_absent_hash`/`builtin_handler_hash`, `sandbox_stack`/`sandbox_counter`, `loader_authorized`, `message_has_location`); `store.mli` exposes the write choke points (`store_object`/`store_trace`/`atomic_write` — the A″4 crash-harness seam) and hides path plumbing, lock internals, and store-lifecycle helpers. Verified with teeth: adding `Store.obj_path` (now private) to another module fails `dune build` with "Unbound value". The build itself is the exit test; further `.mli` coverage proceeds opportunistically. |
| A′5 | **One sub-grammar, two contexts** | De-duplicate `reader_braces.ml` (2,041 lines): the normal and `quasiquote{}` paths share near-verbatim parses (e.g. handler pairs at ~778 and ~1359 on master). Factor each form's parser into a single function parameterized by context so a form added once exists in both — making A3's CI rule a backstop rather than the mechanism. | done (for the mirror parsers) — two dedups landed. (1) The handler-pair loop is ONE function, `parse_handler_pairs ps ~parse_value` (a `hname` return type each reader maps: normal keeps the string; qq builds `'sym`/`'(quote :kw)`), replacing two ~18-line copies; folding surfaced+fixed a trailing-comma drift (qq accepted it, normal rejected — both now reject). Pinned by `tests/069`. (2) The **entire precedence-climbing spine** — `parse_pipe/or/and/cmp/add/mul/postfix` and the `parse_qq_*` mirror — collapses into one set of `climb_*` functions parameterized by a `spine` ops record; `normal_spine`/`qq_spine` supply the per-context builders (AST nodes vs `qq_chain`/`qq_sym` data), the two newline rules (normal threads `c.nl`; qq peeks infix transparently but postfix opaquely, the A3 fix), and the `|>`/int-index decisions, and `parse_arglist ~elem` is shared by both argument lists. `parse_postfix`/`parse_args`/`parse_qq_args` remain as thin wrappers for external callers. Folding closed a second drift: the qq spine lacked the comparison-chaining check, so `a < b < c` in `quasiquote{}` died with a confusing downstream error — both readers now reject it with "comparison operators do not chain." Net −36 lines; a form added to the spine now exists in both contexts by construction. Behavior-preservation confirmed by the 054 fuzzer (300 programs) + 055 fmt (69 files, LAW-20 hash equality) whole-tree gates and 060–069. **Residual (not duplication):** the `primary`/`head` layers genuinely differ (AST vs quoted data), and A′1 already unified the `$`-head lowering via the `tmpl` DSL — what's left is not closed-set drift. Not gated by the Phase A′ exit criteria (which are A′1–A′4). |

**Exit:**
- Each closed-set string (`"file"`, `"caps"`, `"fs.read"`, …) appears in
  exactly one `.ml` file — verified by a grep-based CI check
- Adding a `Cell.t` constructor without a surface decision fails to compile
- SPEC drift test red on any table/SPEC divergence
- `needs k8s-prod` (named composed grant) differential-tested green in both
  backends
- Soundness-kernel `.mli`s in place; build enforces them

---

## Phase A″ — Trust kernel verification

A/A′ make the *surface* sound; A″ verifies the kernel the surface rests on
— identity (hashing), authority (the capability algebra), validity (trace
verification), and durability (store/journal). These are the components
where failure is silent and catastrophic (a wrong cached result, a widened
authority), and they are also the smallest — a few hundred lines each —
which is exactly the size where property testing approaches exhaustiveness.

**The anti-balloon rule (DESIGN.md §1 principle 8): coverage is derived,
never enumerated.** Every A″ item must attach its obligation to a compiler
or CI gate — an exhaustive match over a variant, a drift test against a
table, or a harness at a single `.mli` seam — so that extending the
language *forces* the corresponding verification decision. An A″ item whose
maintenance story is "remember to add a test" is rejected as designed.

| # | Item | Detail | Enforcement mechanism | Status |
|---|------|--------|----------------------|--------|
| A″1 | **Injective hash encoding** | `hash_concat` is `String.concat ":"` over parts that include unescaped user strings (paths, symbol names, tags), and `hash_pattern` joins sub-hashes with no delimiter at all — the exact shape where two distinct ASTs can produce one LAW-20 key and pp silently serves a wrong result. Fix the combinator once (length-prefix every part); audit all call sites. | Injective by construction after the fix; guarded forever by A″2's property. | done — `hash_concat` (`types.ml`) now frames each part as `<len>:<bytes>`, so the pre-hash string parses back to the exact part list and distinct part LISTS never collide even when a part holds `:` or is empty. `hash_pattern`'s two delimiter-free `String.concat ""` joins (`PList`/`PTagged`) now route their sub-pattern lists through `hash_concat` (injective without relying on the 64-char sub-hash accident). Audit of every content-hash construction: `env_extend_hash`/`hash_bindings_flat` rerouted through `hash_concat` (were raw `String.concat ":"` over binding names); `argv_observed_hash` was already `hash_concat` so it is now framed for free; `store.ml`'s `env_observed_hash` had a real same-class collision — value `"absent"` hashed identically to an unset var (`hash_string ("env:"^s)` == `hash_string "env:absent"`) — now distinct `env-present`/`env-absent` `hash_concat` tags; `stat_kind_hash` left as-is (closed 3-element set, already injective). Hash-affecting across the whole store: the `store-v1` golden fixture (037 clause a) was regenerated (object `c465…`→`b2dcf9…`, trace `3713…`→`5bdfa2…`), both backends byte-identical, as the receipt. Near-miss corpus pinned by `tests/070` (env-absent and argv `[a,b]` vs `[a:b]` both recompute across the two world-states and re-hit on return, both backends). The permanent guard is A″2's generated-AST injectivity property — now landed, and it caught a residual same-class collision A″1 missed (`hash_expr EIsland` `None` vs `Some ""`; see A″2). |
| A″2 | **Derived generators + kernel properties** | One QuickCheck-style generator each for `Types.expr`, `pattern`, and `value`, written as an exhaustive match over the variant. Properties running under it: (i) distinct ASTs ⇒ distinct `hash_expr` (injectivity); (ii) `quote_to_value`/`value_to_expr` round-trip totality; (iii) both printers round-trip with hash equality. | Adding a constructor breaks the generator's compile until handled — which extends *every* property at once. No per-feature test list exists. | done — `src/kernel_props.ml` holds the three generators, driven via `pp --check-kernel-props [--seed N] [--count K]` and gated by `tests/071`. The ratchet is a **compile cascade**: adding an AST constructor breaks `*_kind : t -> tag` (warning-8-fatal under dune dev — proven by deleting an arm), whose new tag then breaks `*_gen_of_tag : tag -> t` (forces a generation recipe) and `expr_surface` (forces a round-trip decision) — so one constructor forces three explicit choices and extends every property at once. **(i) Injectivity:** distinct-⇒-distinct over `hash_value`/`hash_pattern`/`hash_expr` on adversarial corpora (':'-laden strings, the `absent` sentinel, empty parts, non-finite floats; NaN/-0.0/improper-pair/`VSet`-ordering hazards excluded or canonicalized so structural `=` and the hash agree) plus a pinned near-miss corpus. **(ii) Quote RT** is stated as the true macro law — `rt = value_to_expr ∘ quote_to_value` is total and **idempotent** (`rt(rt e) ≡ rt e`); plain expr-identity is provably not a law (a symbol call, a literal list, and `(vector …)` all reflect to one canonical fixpoint). **(iii) Print RT** is hash equality of `read (print e)` over the reader-image subset, gated by a recursive `printable` predicate off the per-form surface table (documented opt-outs: sexpr-`match` is C4, `$config` is B5, etc.); printer `Unprintable` refusals are skipped-and-counted (~28% — no silent caps), a printer *crash* or drift fails. Two real defects were caught and fixed *by* the property (each now pinned): `hash_expr EIsland` conflated `None` with `Some ""` (an A″1-class LAW-20 collision A″1 missed), and `printer_braces` printed tagged patterns as `[:tag …]` (reader wants `(:tag …)`) and spread-only list patterns with a leading comma `[, …r]` — both broken `pp fmt` round-trips. This *is* the permanent guard A″1 named. |
| A″3 | **Executable SPEC** | Every law with a `holds` status marker gets at least one pinned test; tests declare `# pins: LAW-<n>` markers. A CI script cross-references SPEC law IDs against test markers. Backfill in tranches, kernel laws first (identity: 20; caps: M3 bans; traces: 23–28; handler restore: 27; failure caching: 28). | The linkage script is the gate: a law marked `holds` with zero pinned tests is a red build — laws can be added, never quietly. | done — the gate is `tests/072-law-pins.sh`: it parses every `### [LAW n]` + **Status** from SPEC, collects the `# pins: LAW-<n>` markers declared by the suite, and fails the build if a **holds** law has neither a pin nor an explicit PENDING entry. Three ratchet teeth, each proven red: an unpinned **holds** law, a pin naming a nonexistent law id (typo/rename/deletion), and a stale-or-promotable PENDING entry. Tranche 1 backfilled — identity 19/20, caps M3-bans 22/22b/23/25/39, traces 21/23–28, handler restore 27, failure caching 28 — pinned across `tests/009/011/012/013/015/016/020/040/044/capability-adversarial/073/075` (40 laws parsed; of 25 **holds**, 9 holds-laws pinned + 16 on the documented PENDING tail = all 25 accounted for). SPEC's status-marker preamble now documents the gate; the tail is paid down under it and any regression is a red build. |
| A″4 | **Crash-injection at the durability seam** | All durable writes route through the journal/store choke points exposed by their A′4 `.mli`s. Harness: kill at every write boundary, restart, assert the store is valid-or-invalidated — never wrong. | Coverage is the *seam*, not a site list: new write paths must route through the tested choke point because the `.mli` leaves no other way. | done — a crash oracle lives in `Store.atomic_write` (the single durable-write choke point `store.mli` leaves no way around): `PP_CRASH_AT=<boundary>:<n>` sends an uncatchable SIGKILL at the n-th write, at boundary ∈ {before, mid, pre-rename, post-rename}. `tests/073-crash-injection.sh` sweeps every (boundary, n) over a real two-node build, restarts on the partial store, and asserts the byte-identical clean-build result each time (valid-or-invalidated, never wrong): 20 crash points swept, all recovered. Coverage is the seam — sweeping the counter kills at every write the build performs, so a new durable write path is covered the moment it routes through `atomic_write`. Teeth proven: a mutated `load_object` that serves a wrong value fails the harness. |
| A″5 | **Adversarial world suite** | Fixtures per observation kind: symlink loops and `..` escapes for `file:`/`tree:`, TOCTOU between observe and use, depfile liars for `run-dep!`, clock skew for probes. Each either defeated or recorded as an explicit trust assumption in DESIGN §4 (honest edges) with its blast radius. | Keyed off the A′1 table: a CI rule requires every user-observable head to have an adversarial fixture or a DESIGN §4 entry — new heads can't ship unexamined. | done — adversarial fixtures under `tests/fixtures/adversarial/` for the path-bearing heads (`file`/`glob`/`secret`: symlink-escape, `..`-traversal, symlink-loop, and secret-redaction), each defeated on **both** backends; `env`/`probe` recorded as DESIGN §4 honest edges (E10 ambient env — no locator/traversal surface; E11 volatile probes — contained as a cell, LAW 38) with blast radius. The rule `tests/074-adversarial-worlds.sh` enumerates heads from `pp --dump-surface-tables` (the A′1 single source) and fails unless each has a fixture or a *present* DESIGN §4 edge (a dangling edge mapping is red; proven). This surfaced and fixed a real defect: `$glob` lowered to a nonexistent `list-dir` primitive (dead on arrival) — the `tmpl` DSL gained a `Perform` node so `$glob` now lowers to `(perform tree-observe …)`, recording the `tree:` cell its doc promises, working on both backends and inside `quasiquote{}`. Hash-affecting only for the generated SPEC surface-table block (regenerated; A′2 drift test green) — no `$glob` user existed to re-key. |
| A″6 | **Capability algebra properties** | Generator over capability values (exhaustive over the kind variant); property: no sequence of user-reachable operations (`cap-restrict`, `cap-compose`) widens authority — `cap_subseteq` monotonicity. Plus the node-boundary bans (no authority/sealed in free vars or results) property-tested, not just unit-tested. | Same compiler ratchet as A″2: a new capability kind breaks the generator until handled. | done — `kernel_props.ml` gained a generator over `capability` values, exhaustive over the kind variant (same compile cascade: `cap_kind` → `gen_cap_of_tag`), with four algebra properties running under `--check-kernel-props` (gated by `tests/075-cap-props.sh`): (a) a raw `CapRestrict` grants nothing its underlying cap didn't — attenuation never widens; (b) `CapCompose` grants **exactly** the union of its parts (invents nothing, loses nothing); (c) the with-caps ⊆ gate (`cap_subseteq`, LAW 22b) is *sound* — an approval never lets through authority the ambient lacks, checked against the very `check_*` functions each effect enforces; (d) the node-boundary ban (`Hasher.contains_authority`, LAW 39) catches a capability/sealed value buried at any depth, with no false positive. ~10k checks/seed over seeds 1/2/3/7/42. Teeth proven: dropping parts from a compose fires (b). |

**Exit:**
- `hash_concat` length-prefixed; injectivity property runs in CI over
  generated AST pairs (with a pinned corpus of near-miss shapes)
- The three kernel properties (A″2) and the caps property (A″6) green and
  wired to the derived generators
- Law-linkage script in CI; identity/caps/trace laws pinned (tranche 1)
- Crash harness kills at every journal/store boundary; recovery asserts
  valid-or-invalidated
- Adversarial fixture (or documented §4 assumption) exists for every
  user-observable head in the A′1 table — checked by CI against the table

**Gating:** Phases B–E remain blocked on A and A′ in full, and on A″1, A″2,
A″6, plus the *mechanisms* of A″3–A″5 existing (linkage script, crash
harness, fixture rule). Law backfill and fixture depth proceed in tranches
alongside later phases — the ratchet prevents regression while the tail is
paid down.

---

## Phase B — Settle the surface (removals & migrations)

Each migration ships with a `pp fmt` auto-upgrade rule and is verified by
the round-trip/LAW-20 gate. Don't hand-edit the tree.

| # | Item | Detail | Status |
|---|------|--------|--------|
| B1 | **Remove cell literals** | Delete the `file:"P"` / `env:"N"` / `tree:"R"` fused-token path (`TCell`); amend SPEC L47–L49 (removed, with rationale: single-string token can't spell defaults or computed paths). `pp fmt` rewrites existing occurrences to `$file`/`$env` — hash-preserving, both lower identically. No deprecation window: pp has no external users, so we take the correct surface now. | done — `TCell` deleted from lexer/parser (both readers)/token type; `:` glued to a name is now only an annotation colon. SPEC §B.1 + L47–L49 amended. No real cell-literal token existed in the tree. Pinned by `tests/076`. |
| B2 | **`collect` becomes a function** | Delete the `collect {}` reader form; expose `collect` (the existing `collect-results` primitive, renamed) as a plain function used in pipelines: `srcs \|> map(compile) \|> collect`. Docs teach the try-vs-collect distinction (short-circuit vs accumulate). | done — `collect {}` reader form + `lower_collect_block` deleted; `collect-results` primitive renamed `collect`; used as a pipeline function. Manual A1 reference updated. Pinned by `tests/058` (rewritten). |
| B3 | **Map update → spread** | Replace `{ m \| k -> v }` with `{ ...m, k -> v }`; spread of multiple maps merges (rightmost wins). `pp fmt` rewrites the `\|` form (it is weeks old). Spread in list literals already ships; this completes the family. | done — `{ ...m, k -> v }` via a shared `parse_map_entries`/`build_map_literal` (normal + qq readers); new `map-merge` primitive; spread-free literals keep their `hash-map` lowering, and a spread-first `{ ...m, … }` lowers to `map-insert(m, …)` (hash-preserving with the old `\|` form). Migrated the 3 stdlib `\|` sites. Map spread inside quasiquote is a B.7 exclusion (eager build). Pinned by `tests/077`. |
| B4 | **Observation exclusivity lint** | `pp lint`: bare `slurp`/`env-get`/`list-dir`/`probe`/`config` outside `stdlib/` warns, pointing at the `$` form. Must run **pre-lowering** (post-lowering, `$secret` and `$file` are identical). | done — `Lint.check_observation_exclusivity` token-scans (`Reader_braces.lex`) before parse; the primitive set is `Surface_tables.observation_primitives` (single source, incl. `perform tree-observe`); `stdlib/` exempt; a `config:` clause is not flagged. Pinned by `tests/080`. |
| B5 | **`$config` joins the family** | `$config(key)` / `$config(key, default)` lowering to the config read, recording `config:` cells. The family now covers every traced read kind. | done — new `config` `obs_head` via a `Config` node in the `Surface_tables` tmpl DSL (config is the `EConfig` special form); both readers derive it, so qq parity is free (A′1). `Cell.Config` → `Surfaced "config"`; SPEC §B.8 regenerated; DESIGN §4 E12 (config is ambient, no traversal surface) keeps `tests/074` at 6/6. Pinned by `tests/078`. |
| B6 | **Remove `cond {}`** | Delete the form outright (young, nothing depends on it); `match` with guards (C3) plus flat `else if` chains cover it. Removal may land with C3 in one change. | done — `cond {}` reader arm deleted; `cond` is an ordinary identifier again. (Landed standalone, not with C3.) Pinned by `tests/076`. |
| B7 | **Remove postfix `?`** | Delete the `expr?` unwrap path inside `try {}`; `<-` is the one propagation spelling. | done — the `expr?` / `let x = expr?` unwrap removed in both the normal and quasiquote try parsers; a stray postfix `?` now errors. A plain `let x = e` inside `try {}` is an ordinary sequential binding. Pinned by `tests/076`. |
| B8 | **Delete `@` attributes** | Remove the parse-and-passthrough attribute code entirely (`@needs` that doesn't narrow authority is a lie in a capability language; `@cache` would duplicate `node`). | done — the `@attr` parse-and-passthrough arm is replaced by a parse error pointing at `node`/`needs`. 0 tree usages. Pinned by `tests/076`. |
| B9 | **`with{}` handlers regularized** | `handlers: { :name -> fn, ... }` map-valued clause replaces the `handler name:` two-token key. Handler sets become first-class composable values. | done (surface) — `handlers: { :name -> fn, ... }` map-valued clause; `Surface_tables.with_clauses` row flips `handler`→`handlers` (SPEC §B.8 regenerated). The reader extracts the literal map's `:name -> fn` pairs into the existing `EWithHandler`, so both backends + the trust kernel are untouched. Pinned by `tests/079`. **Follow-up:** handler-set *values* passed as a variable need `EWithHandler` promoted to a runtime map (hash-affecting, kernel-adjacent) — deferred; the clause takes a map literal today. |
| B10 | **Uniform `!`** | Rename effect wrappers that lack the suffix (`run-dep` → `run-dep!`, sweep stdlib/demo/manual). `!` = "performs an effect", nothing else. | done — effect `run-dep` → `run-dep!` at the shared `Evaluator.perform_effect` dispatch (both backends); every `perform run-dep(…)` swept (stdlib/demo/tests/manual); SPEC L41 updated. Hash-affecting (a real rename). Covered by `tests/022`/`024`/`048`. **Note:** the broader `run!`/`write!`/`log!` wrapper surface (SYNTAX §4, callable without `perform`) is out of B10's stated scope — needs reader sugar or the C2 `apply` primitive. |
| B11 | **Doc scrub** | Purge from all docs/examples: dot-method calls (`src.replace-ext(...)` — currently parses as a call to a global literally named that), `key:` data maps (`register-domain` examples use `->` maps as `stdlib/domain-fs.pp` already does), bare `"{x}"` interpolation (f-strings only). Add the `.`-in-identifier lint (allowed only in grant descriptors). | done — the `.`-in-identifier lint flags any dotted `ESymbol` (grant descriptors lower to `cap-restrict` before lint sees the AST). Doc/example scrub: the runnable tree is already clean of dot-calls, `key:` maps, and bare `{x}` interpolation (verified by grep + `pp lint`); the remaining prose hits are Typst code and the DESIGN §6 rejected-feature example. Lint pinned by `tests/080`. |
| B12 | **Tagged-value convention checks** | CONVENTIONS content in SYNTAX.md §2/§15 backed by lint: flag functions returning `[:err, _]` on one branch and a bare value on another; flag `car`/`cdr` applied to a result-shaped value. | done — `pp lint` flags (i) a function returning `[:err, _]` on one branch and a definitely-bare value on another, and (ii) `car`/`cdr`/`first`/`rest` applied to a tagged result literal `[:ok, _]`/`[:err, _]`. Heuristics kept conservative (unknown-shape branches and non-literal `car` args not flagged) to avoid false positives. Pinned by `tests/080`. |

**Exit:** grammar contains one form per concept; `grep` for any removed
form returns nothing outside CHANGELOG; full tree reformatted by `pp fmt`
with hash equality; `build-self.sh` and `build-lua.sh` null-rebuild with 0
recomputes.

---

## Phase C — The missing sugar (additions)

| # | Item | Detail | Status |
|---|------|--------|--------|
| C1 | **f-strings** | `f"..."` (prefix glued to quote), `{expr}` holes lowering through a new generic `->string`. Ordinary strings never interpolate. Pre-flip audit: one-time lint pass flagging existing strings containing literal `{`. | done — the lexer recognizes the glued `f"…"` prefix (a lone `f`; `foo"…"` still lexes as name+string) and scans literal text + `{expr}` holes into `fseg` segments (`reader_braces.ml`): `{{`/`}}` are literal braces, a hole balances nested `{}` and copies inner string literals verbatim, its RAW source re-lexed and parsed by the reader IN CONTEXT (`parse_expr` normally, `parse_qq` inside a quasiquote — so a hole may contain `unquote(...)`). Lowers to `string-append`/`->string`; a single part (`f"abc"` or `f"{x}"`) is emitted bare, so `f"abc"` is the SAME AST as `"abc"`. New `->string` primitive: a string renders as itself (no quotes — the point of interpolation), every other value via `string_of_value` (deep-forced, sealed redacted). One-way sugar → round-trips through `pp fmt` hash-preserved. Ordinary strings never interpolate. Pinned by `tests/081` (both backends + qq parity + fmt hash). The pre-flip `{`-in-string lint is a documented residual (no interpolation ambiguity exists, so it is advisory only). |
| C2 | **Call spread / `apply`** | `f(a, ...rest, b)` via a new `apply` primitive (evaluator + VM). Motivating case: `run!("cc", ...flags, "-o", out)`. | done — a spread anywhere in a call's argument list lowers `f(a, ...rest, b)` to `apply(f, list(a), rest, list(b))`: consecutive plain args grouped into one `list(...)` segment, each spread its own segment (`group_call_segments`, shared by both spines; `parse_call_args` is the spread-aware arg parser). The new `apply` primitive (`primitives.ml`, reusing `call_with_args` — one impl for both backends) concatenates the segments and calls f; only list SPINES forced, elements pass through like `cons`. Spread-free calls keep the plain `EApply` (hash-preserving). Quasiquote parity is free (`apply`/`list` are ordinary symbols — `value_to_expr` reconstructs the identical call). Glued `...f(x)` of a compound target uses the spaced `... f(x)` form, exactly as list-literal spread already does. Pinned by `tests/082` (both backends + qq + the bare `apply`). |
| C3 | **`match` guards** | `pat if cond => expr` in both backends. With C3 landed, B6 (remove `cond`) completes. | done — `EMatch` arms became `(pattern * expr option * expr)`; a `None` guard hashes/quotes EXACTLY as the pre-C3 2-tuple (guardless matches keep their LAW-20 keys — hash-preserving). Tree-walker evaluates the guard under the pattern's bindings (only nil/false falsy); the compiler folds it INTO the arm condition (`pat_cond AND guard-under-binds`) so the fall-through stays single and closure-free. Both readers parse `pat if guard =>` (normal + qq); both printers emit it; `kernel_props` generates guarded arms (injectivity/quote-RT/print-RT extended for free). Pinned by `tests/083`. **Two pre-existing match VM bugs surfaced by the C-phase fuzzer and fixed:** (i) matching a list/tagged pattern against a non-pair scalar lowered to `car(scalar)` and crashed the VM while the tree-walker fell through — the compiler's list/tagged `pat_cond` is now cons-guarded (`pair?` added to the unshadowable alias set); (ii) a match nested in another match's scrutinee collided on the fixed compiler temp `__match_` in the shared VM frame — the temp is now unique per instance (offset-derived; never hashed). Both pinned by new cases in `tests/057`. |
| C4 | **Sexpr surface for `match`** | The sexpr reader/printer learn match, so match-using files rejoin the round-trip sweep — restoring the strongest cross-reader invariant. | done — `reader.ml` gained `parse_match`/`parse_sexpr_pattern`: `(match scrutinee (pat [if guard] body) …)`, the exact grammar `printer_sexpr` emits (patterns `_`, a literal, a bare symbol, `(list p… [. rest])`, `(tagged tag p…)`; a guarded arm is `(pat if guard body)`, `if` the splitting marker). Match files now round-trip braces→sexpr→braces hash-preserved and the whole-tree `tests/055` sweep needs no match exclusion. The C4 sexpr reader ALSO unblocked the fuzzer generating `match` (with guards) — now round-tripped through both surfaces × both backends over 1500+ programs. Pinned by `tests/084` (+ 057 for hand-written sexpr). |
| C5 | **Map patterns** (stretch) | `{:key -> pat, ...}` as a new pattern kind inside `match` — a pattern kind, not a new form. | deferred (documented scoping decision) — C5 is an explicit stretch goal, absent from Phase C's exit criteria, and its surface is underspecified (open-match vs rest-binding, key evaluation). Deferred rather than guess a semantics; a follow-up adds `PMap` as a new pattern kind (touches `types.ml` hash/match/quote, `compiler.ml` `pat_cond`/`pat_binds`, both printers, all three readers, `kernel_props` — all additive, no existing pattern re-keyed). |

**Exit:** the SYNTAX.md §16 showcase's C-forms (call spread
`run!("cc", ...($config("cflags", [])), …)`, f-strings, `match`) parse and
round-trip hash-preserved in both surfaces; the round-trip sweep (`tests/055`)
covers 100% of `.pp` files with no match exclusion; the fuzzer generates
guarded `match`/`apply`/`->string` and round-trips them through both surfaces ×
both backends. **Residuals** (pre-existing, not C-phase): the showcase's `reads`
node clause is not yet implemented in the brace reader (a Phase-A/§3 gap,
independent of Phase C); C5 (map patterns) deferred; the C1 `{`-in-string
pre-flip lint is advisory-only (documented above).

---

## Phase D — Deep semantics (stretch)

| # | Item | Detail |
|---|------|--------|
| D1 | **One-shot resumable effects** | Explicit `resume(v)`, dynamically checked one-shot (second call errors, deterministically, in both backends). Current handlers are already implicit one-shot resumption (the handler's return value is the resume in tail position) — this admits and generalizes that. **Multi-shot is rejected** until someone answers which trace entry a re-entered `perform` writes (see DESIGN.md §6). |
| D2 | **Tail-call modulo cons** | Unchanged from v1; stretch. |

---

## Phase E — Migration & documentation

| # | Item | Status |
|---|------|--------|
| E1 | Reformat the entire tree (`stdlib/`, `tests/`, `examples/`, `demo/`, manual chapters) via `pp fmt` per B-phase rules; `dune runtest` after each batch. | done (verification) — the tree was already brace-authored and settled (M7 S3); no tree file uses the new C sugar, so nothing needed re-lowering. The `tests/055` whole-tree sweep (69 files) is the standing check that every `.pp` re-reads to its own LAW-20 hash under `pp fmt` both directions — green. No blind rewrite performed. |
| E2 | Manual: language-reference and style chapters re-authored against SYNTAX.md; every example executed. | partial — `A1-language-reference.typ` updated for Phase C: the stale `== The cond conditional` section (documenting the B6-removed `cond`, and referencing the missing `ref-cond` example) is replaced by a `== Pattern matching` section covering `match` + guards; `== Strings` gains an f-string subsection; `== Spread in lists` becomes `== Spread` covering call spread. Every inline `pp` snippet was executed on both backends. **Residual:** the manual has *pre-existing* dangling `#example(...)` refs to example files never registered in the centrally-owned `docs/manual/build.pp` manifest (`ref-list-vec-literals`, `ref-index-access`, `ref-map-update`, `ref-try`, `ref-collect`, `ref-sigils`) — a Phase-B-era manual drift, independent of C; this edit removed two of them (`ref-cond`, `ref-spread`) by folding them into inline snippets. Fully re-authoring the manual + fixing those refs (which needs the off-limits manifest per AUTHORING.md) is a separate task. |
| E3 | AGENTS.md style section regenerated from SYNTAX.md §15 (single source of truth). | done — the `## Style` section already carried match-guards, f-string interpolation, and map spread; added the `...` spread family (list/call/map) row so all of §1's sigil meanings are represented. |
| E4 | CHANGELOG entry per removed/changed form, with the one-line rationale and the fmt rule that migrates it. | done — a **Phase C** section under `[Unreleased]` documents C1–C4 (one bullet each, with the lowering and the hash-preservation note), C5's deferral, the two pre-existing `match` VM fixes, and the `dune runtest` DESIGN.md dep fix. |

**Final exit criteria (whole plan):**
- Every `.pp` file in the tree parses under the settled grammar and only it
- `pp lint` clean over the tree; observation-exclusivity, dot-identifier,
  and tagged-shape rules active
- `build-self.sh` / `build-lua.sh` null-rebuild: 0 recomputes
- Manual rebuilds with every example executing
- SPEC amendments A7 merged; SPEC and SYNTAX.md agree everywhere
