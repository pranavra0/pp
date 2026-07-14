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
> `pragmatic-suffix-conventions` @ `2f817c8`, 2026-07-14. Any edit to a
> status entry must update this pin. A status table that doesn't name its
> ref is a defect (this bit a reviewer once already).

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
| A2 | **Quasiquote/list divergence** | Inside `quasiquote {}`, `[...]` still lowers to `vector` while ordinary code lowers to `list` — a macro template builds a different value than the code it generates. Align the quasiquote path with L9 (list). | open |
| A3 | **Quasiquote coverage of new sugar** | None of `try`/`match`/`$KIND`/`m[k]`/spread parse inside `quasiquote {}`. Implement each (or document as a B.7 exclusion with rationale). Add the CI rule: every new `parse_head` arm appears in `parse_qq_head` or in B.7. For table-driven forms (`$` heads, `with` clauses, grant sugar) parity comes free from A′1/A′5; this item covers the block forms (`try`/`match`/spread/`m[k]`). | open |
| A4 | **`else`-newline misparse** | `parse_if` doesn't `skip_nl` before checking `else`, so `}\nelse {` silently parses as no-else + stray symbol + map literal. Fix in the **parser** (accept newline before `else`); `pp fmt` normalizes to `} else {`. | open |
| A5 | **Match lowering shadowing hazard** | The compiler lowers `match` via `EApply(ESymbol "car"/"="/"nil?"/"not"/...)` — user code shadowing those names diverges the VM from the tree-walker (which matches structurally). Route the lowering through unshadowable internal primitives; add a fuzz case that shadows `car` inside a match arm. | open |
| A6 | **`$KIND` takes expressions** | `$file`/`$glob`/`$secret` currently accept string literals only; real code computes paths (`demo/deploy.pp:68`). Accept arbitrary expressions in all `$` heads (incl. `$env` name + default). Without this the exclusivity lint (B4) is impossible. Implemented *via* A′1: table-driven heads parse their arguments as ordinary expression lists uniformly, so per-head literal restrictions cannot exist. | open — lands with A′1 |
| A7 | **SPEC honesty amendments** | (i) L9 re-pointed at `list`, marked **revised, not sugar** — the bracket change was hash-affecting and the golden-store fix commit is the receipt; add a `pp check` sweep for `vector-get`/`vector-length` on bracket literals. (ii) B.1 gains the `->` glue sentence with the `string->number` example. (iii) LAW 4 gains the documented `try {}` exception: `<-` bindings are sequential, rebinding shadows; pin with a differential test that rebinds a name twice. | open |
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
| A′1 | **`surface_tables.ml` — the closed sets as data** | One module holding the typed tables every other layer derives from: (i) **observation heads** — `{head; cell_kind; lowers_to; arity; qq_legal; doc}`, produced by an *exhaustive* function over `Cell.t` returning `` `Head spec `` or `` `RuntimeRecorded reason `` so every cell kind carries an explicit surface decision (adding a Cell constructor without deciding its surface story becomes a compile error; the pass will force currently-undecided kinds — e.g. `Stat`, read today via `file-exists?`, must either join as `$stat` or be a documented lint whitelist entry); (ii) **`with` clauses** — `caps`/`config`/`handlers` → wrapper constructor; (iii) **grant descriptor sugar** — `fs.read`/`fs.write`/`fs.rw` → restrict mode. Consumers: both readers (normal *and* quasiquote paths), `lint.ml` whitelists, the fuzzer's generators, and error messages ("unknown observation `$foo`; known heads: …" listed from the table). Head arguments parse as ordinary expression lists uniformly — subsumes A6. | open |
| A′2 | **SPEC drift test** | The tables render to a generated block (between markers) in the SPEC appendix; a CI test regenerates and diffs. No closed set is ever hand-listed in SPEC again — the doc-sync failure mode (D10) becomes a red build, not a stale paragraph. | open |
| A′3 | **`needs` value-openness made normative** | Document in SYNTAX.md §5 and SPEC: `needs` accepts any expression evaluating to a capability; the dotted descriptors are table-driven sugar (A′1). Named grants are ordinary bindings — `let k8s-prod = cap-compose(net("k8s.prod.internal"), process)` … `node deploy() needs k8s-prod { … }`. Add differential tests (both backends) for named/composed grants and for the sugar. The capability *kind* set stays closed — see DESIGN.md §1 principle 7 for why it cannot "run out". | open |
| A′4 | **Compiler-enforced module seams** | Add `.mli` interfaces to the soundness kernel first — `cell`, `capabilities`, `hasher`, `store`, `runtime` — exposing only the intended API (e.g. `Runtime.record_read` stays; its internals don't). Then the surface layer: `surface_tables`, `desugar`. Exit test: `dune build` fails if any module reaches around a seam. This is the down-payment on "clear abstraction boundaries"; further `.mli` coverage proceeds opportunistically. | open |
| A′5 | **One sub-grammar, two contexts** | De-duplicate `reader_braces.ml` (2,041 lines): the normal and `quasiquote{}` paths share near-verbatim parses (e.g. handler pairs at ~778 and ~1359 on master). Factor each form's parser into a single function parameterized by context so a form added once exists in both — making A3's CI rule a backstop rather than the mechanism. | open |

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
| A″1 | **Injective hash encoding** | `hash_concat` is `String.concat ":"` over parts that include unescaped user strings (paths, symbol names, tags), and `hash_pattern` joins sub-hashes with no delimiter at all — the exact shape where two distinct ASTs can produce one LAW-20 key and pp silently serves a wrong result. Fix the combinator once (length-prefix every part); audit all call sites. | Injective by construction after the fix; guarded forever by A″2's property. | open |
| A″2 | **Derived generators + kernel properties** | One QuickCheck-style generator each for `Types.expr`, `pattern`, and `value`, written as an exhaustive match over the variant. Properties running under it: (i) distinct ASTs ⇒ distinct `hash_expr` (injectivity); (ii) `quote_to_value`/`value_to_expr` round-trip totality; (iii) both printers round-trip with hash equality. | Adding a constructor breaks the generator's compile until handled — which extends *every* property at once. No per-feature test list exists. | open |
| A″3 | **Executable SPEC** | Every law with a `holds` status marker gets at least one pinned test; tests declare `# pins: LAW-<n>` markers. A CI script cross-references SPEC law IDs against test markers. Backfill in tranches, kernel laws first (identity: 20; caps: M3 bans; traces: 23–28; handler restore: 27; failure caching: 28). | The linkage script is the gate: a law marked `holds` with zero pinned tests is a red build — laws can be added, never quietly. | open |
| A″4 | **Crash-injection at the durability seam** | All durable writes route through the journal/store choke points exposed by their A′4 `.mli`s. Harness: kill at every write boundary, restart, assert the store is valid-or-invalidated — never wrong. | Coverage is the *seam*, not a site list: new write paths must route through the tested choke point because the `.mli` leaves no other way. | open |
| A″5 | **Adversarial world suite** | Fixtures per observation kind: symlink loops and `..` escapes for `file:`/`tree:`, TOCTOU between observe and use, depfile liars for `run-dep!`, clock skew for probes. Each either defeated or recorded as an explicit trust assumption in DESIGN §4 (honest edges) with its blast radius. | Keyed off the A′1 table: a CI rule requires every user-observable head to have an adversarial fixture or a DESIGN §4 entry — new heads can't ship unexamined. | open |
| A″6 | **Capability algebra properties** | Generator over capability values (exhaustive over the kind variant); property: no sequence of user-reachable operations (`cap-restrict`, `cap-compose`) widens authority — `cap_subseteq` monotonicity. Plus the node-boundary bans (no authority/sealed in free vars or results) property-tested, not just unit-tested. | Same compiler ratchet as A″2: a new capability kind breaks the generator until handled. | open |

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
| B1 | **Remove cell literals** | Delete the `file:"P"` / `env:"N"` / `tree:"R"` fused-token path (`TCell`); amend SPEC L47–L49 (removed, with rationale: single-string token can't spell defaults or computed paths). `pp fmt` rewrites existing occurrences to `$file`/`$env` — hash-preserving, both lower identically. No deprecation window: pp has no external users, so we take the correct surface now. | open |
| B2 | **`collect` becomes a function** | Delete the `collect {}` reader form; expose `collect` (the existing `collect-results` primitive, renamed) as a plain function used in pipelines: `srcs \|> map(compile) \|> collect`. Docs teach the try-vs-collect distinction (short-circuit vs accumulate). | open |
| B3 | **Map update → spread** | Replace `{ m \| k -> v }` with `{ ...m, k -> v }`; spread of multiple maps merges (rightmost wins). `pp fmt` rewrites the `\|` form (it is weeks old). Spread in list literals already ships; this completes the family. | open |
| B4 | **Observation exclusivity lint** | `pp lint`: bare `slurp`/`env-get`/`list-dir`/`probe`/`config` outside `stdlib/` warns, pointing at the `$` form. Must run **pre-lowering** (post-lowering, `$secret` and `$file` are identical). | open |
| B5 | **`$config` joins the family** | `$config(key)` / `$config(key, default)` lowering to the config read, recording `config:` cells. The family now covers every traced read kind. | open |
| B6 | **Remove `cond {}`** | Delete the form outright (young, nothing depends on it); `match` with guards (C3) plus flat `else if` chains cover it. Removal may land with C3 in one change. | open |
| B7 | **Remove postfix `?`** | Delete the `expr?` unwrap path inside `try {}`; `<-` is the one propagation spelling. | open |
| B8 | **Delete `@` attributes** | Remove the parse-and-passthrough attribute code entirely (`@needs` that doesn't narrow authority is a lie in a capability language; `@cache` would duplicate `node`). | open |
| B9 | **`with{}` handlers regularized** | `handlers: { :name -> fn, ... }` map-valued clause replaces the `handler name:` two-token key. Handler sets become first-class composable values. | open |
| B10 | **Uniform `!`** | Rename effect wrappers that lack the suffix (`run-dep` → `run-dep!`, sweep stdlib/demo/manual). `!` = "performs an effect", nothing else. | open |
| B11 | **Doc scrub** | Purge from all docs/examples: dot-method calls (`src.replace-ext(...)` — currently parses as a call to a global literally named that), `key:` data maps (`register-domain` examples use `->` maps as `stdlib/domain-fs.pp` already does), bare `"{x}"` interpolation (f-strings only). Add the `.`-in-identifier lint (allowed only in grant descriptors). | open |
| B12 | **Tagged-value convention checks** | CONVENTIONS content in SYNTAX.md §2/§15 backed by lint: flag functions returning `[:err, _]` on one branch and a bare value on another; flag `car`/`cdr` applied to a result-shaped value. | open |

**Exit:** grammar contains one form per concept; `grep` for any removed
form returns nothing outside CHANGELOG; full tree reformatted by `pp fmt`
with hash equality; `build-self.sh` and `build-lua.sh` null-rebuild with 0
recomputes.

---

## Phase C — The missing sugar (additions)

| # | Item | Detail | Status |
|---|------|--------|--------|
| C1 | **f-strings** | `f"..."` (prefix glued to quote), `{expr}` holes lowering through a new generic `->string`. Ordinary strings never interpolate. Pre-flip audit: one-time lint pass flagging existing strings containing literal `{`. | open |
| C2 | **Call spread / `apply`** | `f(a, ...rest, b)` via a new `apply` primitive (evaluator + VM). Motivating case: `run!("cc", ...flags, "-o", out)`. | open |
| C3 | **`match` guards** | `pat if cond => expr` in both backends. With C3 landed, B6 (remove `cond`) completes. | open |
| C4 | **Sexpr surface for `match`** | The sexpr reader/printer learn match, so match-using files rejoin the round-trip sweep — restoring the strongest cross-reader invariant. | open |
| C5 | **Map patterns** (stretch) | `{:key -> pat, ...}` as a new pattern kind inside `match` — a pattern kind, not a new form. | stretch |

**Exit:** the SYNTAX.md §16 showcase parses and runs verbatim in both
backends; round-trip sweep covers 100% of `.pp` files again (no match
exclusions); fuzzer generates every C-item form.

---

## Phase D — Deep semantics (stretch)

| # | Item | Detail |
|---|------|--------|
| D1 | **One-shot resumable effects** | Explicit `resume(v)`, dynamically checked one-shot (second call errors, deterministically, in both backends). Current handlers are already implicit one-shot resumption (the handler's return value is the resume in tail position) — this admits and generalizes that. **Multi-shot is rejected** until someone answers which trace entry a re-entered `perform` writes (see DESIGN.md §6). |
| D2 | **Tail-call modulo cons** | Unchanged from v1; stretch. |

---

## Phase E — Migration & documentation

| # | Item |
|---|------|
| E1 | Reformat the entire tree (`stdlib/`, `tests/`, `examples/`, `demo/`, manual chapters) via `pp fmt` per B-phase rules; `dune runtest` after each batch. |
| E2 | Manual: language-reference and style chapters re-authored against SYNTAX.md; every example executed. |
| E3 | AGENTS.md style section regenerated from SYNTAX.md §15 (single source of truth). |
| E4 | CHANGELOG entry per removed/changed form, with the one-line rationale and the fmt rule that migrates it. |

**Final exit criteria (whole plan):**
- Every `.pp` file in the tree parses under the settled grammar and only it
- `pp lint` clean over the tree; observation-exclusivity, dot-identifier,
  and tagged-shape rules active
- `build-self.sh` / `build-lua.sh` null-rebuild: 0 recomputes
- Manual rebuilds with every example executing
- SPEC amendments A7 merged; SPEC and SYNTAX.md agree everywhere
