# M7 design — the brace surface: a second reader, the same language

**Thesis.** LAW-20 keys computations on *expanded form*, so surface syntax is
provably not part of a program's identity. M7 exploits this: a brace/infix
surface syntax is added as a second reader that parses to the **identical
`Types.expr` AST**, and the entire tree is migrated to it — with the store as
the witness that nothing changed. Zero changes to the evaluator, VM, compiler,
macro expander, store, codec, hasher, traces, or capability semantics.

**Homoiconicity is preserved at the AST layer** (the Elixir position): `quote`
still yields sexpr data, `defmacro` still consumes and produces sexprs,
`quasiquote`/`unquote` still work. The sexpr language is demoted from "the
syntax" to "the AST" — documented in the macro chapter, written by macro
authors, displayed by tooling on request. The brace text is not itself the
data structure; `quote { … }` is the bridge.

**The elegance criterion (frozen).** Migrating a file may not change any
LAW-20 key. Concretely: transpile `build.pp` to braces, run the 101-TU build —
**null rebuild, 0 recomputes**. The store cannot tell the migration happened.

## Non-negotiable consequences of the criterion

1. **No renames.** LAW-20 hashes code including symbols; `string-index` →
   `string_index` would invalidate every trace. Kebab-case identifiers
   survive. Therefore:
2. **Infix operators require surrounding whitespace.** `a - b` is
   subtraction; `a-b` is an identifier. One tokenizer rule buys
   hash-preservation for the entire stdlib. (Prior art: Agda, and every
   Lisp-family infix experiment that didn't mass-rename.)
3. **Reader-level desugars are shared, not duplicated.** `assert`, per-param
   type annotations (LAW 32), and any future sugar run as a common post-pass
   over the AST, downstream of *both* readers.

## Grammar decisions (S0 freezes these)

- **Blocks:** braces + newline-as-separator; `;` available as an inline
  separator. NOT whitespace-sensitive — pp programs generate pp programs.
- **Application:** `f(x, y)`. **Pipeline:** `x |> f` ≡ `f(x)` (reader-level,
  lowers before hashing — a pipeline and its spelled-out form are the same
  computation).
- **Bindings:** `let x = e` (≡ `(def x e)` value-binding semantics, LAW 4),
  `fn(x) { … }`, `def f(x) { … }`, `node f(x) … { … }` (≡ `defnode`).
- **`needs` clause:** `node compile(tu) needs fs.read("src"), proc { … }`
  lowers to the existing M3 attenuation forms (`with-caps`,
  capture-at-creation). Surface syntax for semantics that already exist;
  no new authority model.
- **Cell literals:** `file:"src/main.c"`, `glob:"src/*.c"`, `env:"CC"` —
  lower to the existing cell-observing forms. World-reads get visual
  identity.
- **Effect convention:** names ending in `!` for perform-wrappers (`run!`).
  Convention only in M7 — reader *enforcement* (e.g. `perform` legal only
  inside `!`-named defs) is a separate, later decision; do not couple it to
  the syntax migration.
- **Maps / desired state:** `{ "out/app" -> link(objs) }`; `reconcile { … }`
  is sugar for the existing final-value map.
- **Quote bridge:** `quote { … }` → sexpr data; `unquote(e)`, `splice(e)`
  inside it. `defmacro` authored in braces receives/returns sexprs,
  unchanged in `macro.ml`.
- **Types:** `def f(x: int) { … }` lowers to the LAW-32 located checks.
- **Comments:** `#` to end of line. The formatter must *carry* comments
  through transpilation (the one place round-tripping is fiddly).
- **Identifiers:** `-`, `?`, `!` remain name characters (whitespace rule
  above disambiguates `-`).

## Stages

### S0 — Grammar spec + lowering table
Full token/precedence spec and a form-by-form lowering table (every brace
construct → the sexpr form it reads to), appended to SPEC.md as a
non-normative surface annex. Audit every SPEC law for syntax dependence
(most are semantic; LAW 4, 29, 32 mention surface forms — reword to be
surface-neutral). **Exit:** the table covers every construct the fuzzer's
full grammar can emit.

### S1 — The second reader
`src/reader_braces.ml` → the same `Types.expr`, with source locations
threaded identically (LAW 29 error text must be byte-identical for
equivalent programs). Dispatch by extension during transition: `.pp` = sexpr
(unchanged), `.ppb` = braces; `load`/islands handle both. **Exit (the gate):**
the fuzzer grows a sexpr→brace printer and, for both grammars, asserts
print→re-read gives AST equality *and* LAW-20 hash equality — the round-trip
property is fuzzed, gating, alongside the existing two-backend differential
(the suite becomes 2 readers × 2 backends).

### S2 — `pp fmt`
The pretty-printer as a tool: `pp fmt --to-braces` / `--to-sexpr`, lossless
including comments. This is both the migration vehicle and the display layer
`pp why` / `pp graph` / REPL will use. **Exit:** for every `.pp` file in the
tree, `to-braces | to-sexpr` round-trips to an expanded-form hash identical
to the original.

### S3 — Migrate the tree (mechanically)
`pp fmt` converts stdlib (5 files), `build.pp`, tests (16 programs +
`gen-cproject.pp`/`mutate-cproject.pp`), examples, demo, and the manual's
executed examples. Nothing is hand-rewritten in this stage. **Exit:**
`dune runtest` green with no test logic changes; `build-self.sh` and
`build-lua.sh` **null-rebuild with 0 recomputes** against a store populated
pre-migration; the manual rebuilds with every live example executing.

### S4 — Flip the default
Braces take `.pp`; sexpr files become `.ppl` ("the AST form"), still fully
supported forever (it *is* the macro layer). REPL reads braces (multi-line
balance detection redone for brace/paren/string nesting). `pp why`, errors,
and `pp graph` print braces via the S2 printer. **Exit:** `tests/027`
(error messages) and `tests/029` (REPL) pass re-pinned; a `.ppl` island
loads from a `.pp` program and vice versa.

### S5 — Macro ergonomics
`tests/041-defmacro.pp` re-authored in braces via `quote{}`/`unquote()`;
manual macro chapter rewritten to teach "braces on the surface, sexprs as
the AST" with the Elixir framing. **Exit:** every existing macro test passes
authored in either surface, differentially.

### S6 — Docs
Manual chapters, README, SPEC examples converted; sexprs appear only in the
macro chapter and GLOSSARY. The Lua-style site (Maturity §5) launches on the
brace surface only.

## Risks / residuals

- **Comment preservation** through `pp fmt` is the only lossy hazard —
  gate S3 on a comment-count + content check, not just hash equality
  (hashes ignore comments by construction).
- **Two documented syntaxes is worse than either** — S4/S6 exist to prevent
  it. After S6, braces are *the* surface; `.ppl` is documentation-of-the-AST,
  not a parallel dialect.
- **Grammar creep:** infix niceties must stay reader-level lowering; any
  proposal that can't be expressed as a row in the S0 lowering table changes
  the *language* and is out of M7's scope.
- **Sequencing:** M2.3's first green Linux CI run and the v0.2.0 tag should
  land *before* S3 — migrating the tree on top of unproven CI compounds two
  unknowns. D23/D24 are orthogonal (backend divergences, not reader work)
  but are cheap and should not wait behind M7.
- **Sizing:** reader.ml is 865 lines; expect ~1.5–2k for the brace reader,
  a few hundred for the printer, and the fuzzer printer. The migration
  itself is mechanical by construction.
