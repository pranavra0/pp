## Context

Finish `pp` as a coherent, beautiful programming language while deliberately excluding the network simulator in `docs/PLAN-network-simulator.md` and the separate CUE interop issue (#16). “Done” means closing the confirmed semantic and frontend bugs, replacing raw/contradictory surfaces with one canonical language model, completing modules, projects, tests, and the standard library, erasing obsolete compatibility paths and aspirations, and proving the result through the binary, suite, architecture gates, and both fuzzer grammars. Keep the public version at `0.2.0-dev`; this is a completion cutover, not a 1.0 stability declaration.
## Approach

1. Close current correctness holes before adding surface area.
   - In `src/frontend/reader.ml`, `src/frontend/printer_braces.ml`, `src/app/command_frontend.ml`, and `tools/fuzz.ml`, make every checked `.ppl → .pp → AST` round trip preserve top-level form count and `Identity.hash_expr`. Pin `(def p32 +)`, `(def p28 p28)\n(let* [x29 -43 x30 x29] \"q0\")`, `(print 55)`, and every committed round-trip repro. Teach the brace printer to emit operator names as ordinary values and to use compact semicolon-separated blocks when multiple nested locations share a source line; never index application arguments without proving arity. The oracle stops using OCaml structural `=`—range extent/columns are outside identity—but still compares hashes, which include source and start line.
   - Add `Identity.equal_value : value -> value -> bool` as hash equality and use it for language `=`, literal/tagged/map patterns, and map/set membership/replacement; eliminate polymorphic equality over `value`. Add kernel smart constructors `Value.map`/`Value.set`: maps have unique keys with rightmost input winning, sets have unique members, and both store ascending key/element-hash order. Replace every constructing `VMap`/`VSet` occurrence across `src`, tools, and unit fixtures; add an architecture check that permits direct constructors only inside the smart-constructor/codec implementation while pattern matches remain allowed. Route literals/spreads, collection primitives, records, observations, result/process values, codecs, and presentation/iteration through the invariant. Tagged patterns must consume the entire tagged list. Bump `Store_layout` from `pp-store 1` to `pp-store 2`; never reinterpret v1 objects/traces as v2.
   - In `src/runtime/node.ml`, make `resolve_free_variables` force every syntactically referenced free variable and propagate every error; delete the catch-and-retain-thunk fallback. This makes LAW 20’s call-by-value premise true and lets the existing recursive authority scan reject a capability/sealed value reached through a thunk without violating LAW 14: a node free variable is demanded by key construction.
   - In `src/runtime/evaluator_scope.ml`, add a private OCaml effect `Leave_scope : value -> value Effect.t` and one shared scope runner. Evaluate each `with-caps`, `with-handler`, and `with-config` body with a terminal continuation that performs `Leave_scope`; handle it outside `Dynamic_scope.with_*`, discard its captured continuation, then invoke the caller continuation. Exceptions pass through unchanged. This keeps tail recursion bounded while ensuring the caller continuation runs after the dynamic scope has unwound.

2. Replace fragmented world reads with one unshadowable observation AST.
   - In `src/kernel/core_model.ml/.mli`, replace `EConfig` with `EObserve of observation_kind * expr list`, using the exact closed type `observation_kind = File | Env | Tree | Probe | Secret | Stat | Argv | Config`. Update every current `EConfig` callsite (locate with `grep -R '\\bEConfig\\b' src tools tests/unit`) across identity, free variables, quotation, readers, printers, evaluator paths, kernel properties, API-surface allowlist, and vertical-slice checks. The sexpr/AST spelling is `(observe KIND ARG...)`; brace syntax prints and accepts only `$file`, `$env`, `$tree`, `$probe`, `$secret`, `$stat`, `$argv`, and `$config`.
   - Replace the lowering-template `Surface_tables.tmpl` type with rows containing typed kind, brace head, arity, and documentation; both readers and quasiquote construct `EObserve` from the row. Required source arguments are strict, while `$env(name, default)`/`$config(key, default)` evaluate default only when absent. `$file(path)` requires `fs` read and returns `VString`, except node-relative scratch reads are capability-free/unrecorded; `$secret(path)` requires `secret` and always returns `VSealed`, even with `fs`; `$tree(path)` requires `fs` read and returns canonical relative-path→content-hash map; `$probe(name)` returns pass-pinned value; `$stat(path)` authorizes before lookup and returns `:file`/`:directory`/nil; `$argv()` returns arguments; `$env` returns string/default/nil; `$config` accepts string/keyword and returns value/default/nil. Arity/type errors are located and name the head. Route all through `Observation`; retain existing cells and add serialized `Cell.Stat` so each non-scratch read rechecks exactly what it recorded. Extend cell codecs, trace presentation, store/index traversal, property generators, and invalidation tests together.
   - Delete the public raw observation registrations `slurp`, `env-get`, `argv`, `file-exists?`, `dir?`, `probe`, and `config`, plus the undocumented `$glob` spelling. Migrate all exact callsites returned by `grep -R '\\b\\(slurp\\|env-get\\|argv\\|file-exists?\\|dir?\\|probe\\|config\\)(\\|\\$glob' stdlib demo examples tests docs README.md build.pp` to the typed `$` forms. After `stdlib/domain-fs.pp` uses `$tree`, delete the now-redundant public `tree-observe` effect/registration too; keep only its internal host helper. No compatibility aliases remain.

3. Make the documented `!` convention executable without parser magic.
   - Add strict ordinary builtin values `run!`, `run-closed!`, `write!`, `log!`, `http-get!`, and `http-post!` in `src/runtime/primitives.ml`. Each calls `Evaluator_effects.perform ~application:(Session.core_operations …).apply` with the same public effect name and forced arguments. Rename the matching cases in `src/runtime/evaluator_effects.ml` and all handlers/callers from `run`, `write-file`, `log`, `http-get`, and `http-post`; ordinary application means these values remain higher-order and shadowable, while `perform` remains the AST-native dispatch form.
   - Clean-cutover script-tier mutators to `configure-runtime!`, `register-reporter!`, `emit-event!`, `register-domain!`, and `register-probe!`; clean-cutover stdlib/domain mutators to `register-domains!`, `register-fs-domain!`, `register-proc-domain!`, `proc-apply!`, and `each!`. Update the primitive catalog, stdlib, runtime glue, tests, demos, examples, fuzzer, syntax table, lint effect detection, and manual. Keep effect-free constructors (`runtime-manifest`, schedule/policy constructors, result helpers) unsuffixed.

4. Complete modules and source-relative loading.
   - Add `EExport of string list` with brace statement `export name, other` and sexpr `(export name other)`. Update every AST vertical slice found by `grep -R '\\bEModule\\b' src tools tests/unit`. `Evaluator_forms.module_expr` and `module_file` accept exactly zero or one export statement, reject duplicate names and names not defined by that module, and return only exported bindings; no export statement means an empty module. Encountering `EExport` through ordinary `load`, top-level execution, a function body, or a `do` block is a located error. `merge_module` rejects any binding already present in the target environment and names the collision.
   - Treat a direct `defmacro` in a file or module body as a compile-time definition eligible for the same export list. Refactor `Macro`/`Session` to support snapshot/restore scopes: expanding a static `import "PATH"`, `import(island("URI", "PIN"))`, inline module, or `import DEP` where `DEP` is a manifest-known island expands that module from an empty user-macro table (plus its own static imports), then installs only its exported macros before later caller forms; the evaluator independently imports runtime exports. A literal `load("PATH")` retains documented sequential behavior by sharing every loaded-file macro with the caller. Other computed imports provide runtime values only. Module export validation accepts names defined in either phase; macro-only modules evaluate to empty `VEnvMap`; duplicate runtime/macro imports error; inspecting a module never leaks private macros. Cache by resolved source/content and transitive import hashes within the session; test private/exported macros, hermetic modules, static ordering, load leakage by design, project dependency imports, dynamic-import limits, and collisions.
   - Add `Get_source : string Effect.t` plus `Dynamic_scope.with_source`. Both evaluator paths install an `ELocated` range’s source around its inner expression; `Loader.resolve ?source` resolves relative `load`/`load-module` paths against that containing file, with the macro expander passing the import form’s location directly and `-e`/REPL using `Sys.getcwd()`. Add `std:NAME` via `World_path.stdlib_root`: accept one relative module name, map `std:list` to `<stdlib-root>/list.pp`, and reject traversal/missing modules before read. Brace `import "PATH"` canonically lowers to `import(load-module("PATH"))`; retain `import(EXPR)` for first-class module values and use strings for stdlib imports.
   - Make `Reader_braces.read_dispatch` accept only `.pp` (brace) and `.ppl` (sexpr), with explicit synthetic/REPL entry points rather than extension fallthrough. Remove `.ppb`, the island `entry.ppb` fallback, and every `.ppb` fixture/reference. Replace `command_run.ml`’s generated sexpr strings with direct `Core_model.expr` prelude forms so runtime glue does not depend on a fake filename to select a parser.

5. Finish patterns and formatting.
   - Add the closed `map_rest = Exact | Ignore | Bind of string` and `PMap of (value * pattern) list * map_rest`. Brace syntax is `{ LITERAL -> PATTERN, ...REST }`; sexpr syntax is `(map (LITERAL PATTERN) ... [. REST])`, mirroring existing `(list ... . REST)`. Keys must be nil, bool, number, string, keyword, symbol, or recursively closed vector/list literals; duplicate identity-equal keys are parse errors. Exact requires exactly those keys, `_` ignores extras, and a variable binds the canonical residual map. Extend `Pattern_match`, identity, quotation/value conversion, both readers/printers, kernel properties, lints, manual, and full-grammar generation.
   - Replace formatter conversion-in-place. `pp fmt FILE` detects `.pp`/`.ppl`, preserves comments, and atomically rewrites the file in its own canonical surface. `pp fmt --to-braces FILE` and `pp fmt --to-sexpr FILE` convert to stdout only and reject an already-target-surface file. Remove `-i`/`--in-place` and public `--emit-braces`/`--roundtrip-braces`; rename the latter to hidden `--check-roundtrip FILE` for tests/fuzzing. `-h` becomes a real alias of `--help`, both exit 0, and CLI smoke coverage pins help/version/eval/argument-separator/error exit codes.

6. Add one project model using existing island identity.
   - `project.pp` is a brace module. Its canonical initial shape is:
     ```pp
     export project

     let project = {
       :name -> "PROJECT",
       :version -> "0.1.0",
       :entry -> "build.pp",
       :test-roots -> ["tests"]
     }
     ```
     Dependencies are additional sorted bindings `let NAME = island("URI", "PIN")` listed after `project` and added to the single export clause. The inline 64-hex content pin is both declaration and lock; `~/.pp/islands/src/<pin>` remains the package cache. No second manifest, hidden lockfile, solver, registry, package AST form, or ambient auto-update is added.
   - Add a typed `Project_manifest.t` decoder in `src/app/`. Parse the module AST and require exactly one direct `let project = MAP`, zero or more direct `let NAME = island("URI", "PIN")` declarations, and one export containing `project` plus exactly those dependency names; unwrap only locations and reject every other form. Evaluate only the project map with no grants, accepting exactly `:name`, `:version`, `:entry`, and `:test-roots`; require a name matching `[a-z][a-z0-9]*(?:-[a-z0-9]+)*`, SemVer 2.0, a canonically project-contained existing `.pp`/`.ppl` entry, and a nonempty proper list of canonically contained directories; reject symlink escape, duplicate/unknown keys, and non-data values. Project commands locate the nearest ancestor `project.pp`; `--project PATH` explicitly selects one for `add`, `update`, `remove`, `build`, `test`, or an ordinary file/`-e` run.
   - Add CLI variants and `Command_project`: `pp init [DIR]` accepts an absent or empty target, derives/validates `:name` from its basename, stages the complete shown `project.pp`, `build.pp` containing `nil`, and `tests/project_test.pp` containing `import "std:test"\nexpect-true(true)`, then installs without overwriting any entry and cleans its staging tree on failure. `pp add NAME URI` requires an unused non-builtin brace identifier; `pp update [NAME]` repins one dependency or all in lexical order; `pp remove NAME` deletes one. Add `Island.repin : string -> string`, which may fetch/materialize the cache but never edits source; `add`/`update` explicitly authorize fetching, while ordinary builds retain cache-only behavior unless their existing fetch flag is given. `Project_manifest` rewrites only the export and affected binding by parsed ranges, inserts in lexical order, stages, reparses/decodes, then atomically replaces; comments/untouched bytes survive, all repins finish first, and failure leaves the manifest byte-identical. `pp build` evaluates the manifest module, binds each dependency to its island module value in lexical order, then executes `:entry` in the same session. An entry explicitly `import DEP`; the project-aware expander recognizes it for macro exports too.

7. Add project-native tests.
   - Add `pp test [PATH...] [--verbose]`. With no paths, use `:test-roots`; explicit file or directory paths must remain canonically inside the project, including after symlink resolution. Recursively discover `*_test.pp` and `*_test.ppl`, deduplicate and sort normalized relative paths lexically, and error with exit 2 when none exist. Run files sequentially. For each, call `Unix.create_process_env` on `Sys.executable_name` with `--project`, forwarded grants/program arguments, the same `HOME` (shared pinned-island cache), and a unique `PP_STORE_ROOT` under a temporary directory (isolated objects, traces, journals, domains, processes); redirect stdout/stderr to files to avoid pipe deadlock, and remove every temporary artifact with `Fun.protect`.
   - Print `PASS relative/path` or `FAIL relative/path` in discovery order. Suppress passing child output unless `--verbose`; replay failed stdout then stderr under labeled indented sections; finish with `N passed, M failed, T total` (no timing in the deterministic summary). Return 0 only if all pass, 1 for test failures, 2 for command/manifest/discovery errors. Do not stop after the first failure.

8. Finish the standard library with explicit exports and no duplicate primitives.
   - Rewrite existing libraries to the normative brace style and `std:` loads. `list.pp` exports the existing `filter`, `foldl`, `foldr`, `range`, `take`, `drop`, `nth`, `length`, `append`, `reverse`, `member?`, plus `reject`, `range-by`, `each!`, `all?`, `any?`, `find`, `flat-map`, `flatten`, `zip`, `enumerate`, and `partition`; negative indexes/counts and zero steps error, `range-by` uses `< end` for positive steps and `> end` for negative steps, overlong take/drop/nth return the available list/nil, flatten removes exactly one proper-list layer, zip requires equal lengths and returns two-item lists, and partition preserves order as `{:matched -> LIST, :rest -> LIST}`. Remove the stale batching-history comment and keep builtin `map` as the sole map implementation.
   - `map.pp` uses `import "std:list"` and exports `map-has?`, `map-filter`, `map-map-values`, `map-map-keys`, `map-from-pairs`, and `map-to-pairs`; remove its duplicate `map-merge` because the canonical primitive already exists. Pair construction accepts only two-item proper lists, and key remapping/pair construction reject duplicates. Add primitive `vector-length` and the canonical primitive `set->list`, then add `vector.pp` exporting `vector->list`, `list->vector`, `vector-map`, `vector-filter`, and `vector-foldl`, and `set.pp` exporting `set-has?`, `set-insert`, `set-remove`, `set-union`, `set-intersection`, `set-difference`, and `list->set`. These libraries use identity equality and canonical order; no alias or second vector/set representation is introduced.
   - `string.pp` exports `string-join`, `starts-with?`, `ends-with?`, `contains?`, `string-replace`, `string-repeat`, and `lines`. Fix primitive `string-split(s, sep)` to accept any nonempty separator and preserve empty fields; replacement is all non-overlapping matches from the left, repetition requires a nonnegative count, and `lines` removes only the one terminal field created by a final newline. Add `path.pp` with pure lexical `path-join`, `path-normalize`, `path-basename`, `path-dirname`, `path-extension`, `path-stem`, and `absolute-path?`: reject NUL and an absolute segment after the first; preserve an initial `/`; remove `.`, duplicate/trailing separators; resolve `..` but error if it escapes the relative or absolute root; return `"."` as the dirname of a lone relative basename and `"/"` at the absolute root; treat leading/trailing dots as part of a basename, while extension is the suffix after the last interior dot without that dot.
   - Add pure kernel JSON codec entry points `json->value(string)` and `value->json(value)`—no external dependency and no host effects. Decode JSON null/bool/string/array/object to nil/bool/string/vector/string-keyed-map; decode integer-token numbers to `VInt` only when in OCaml-int range, otherwise finite `VFloat`; fully implement escapes and Unicode surrogate pairs; reject duplicate object keys, non-finite/overflow numbers, malformed UTF-8, and trailing input with byte-offset diagnostics. Encode only nil, bool, finite numbers, strings, vectors/proper lists, and maps whose keys are all strings or keywords with no post-conversion collision; preserve float type by emitting a decimal point when needed, sort object keys lexically, and emit compact UTF-8 JSON.
   - Add `result.pp` exporting `ok`, `err`, `ok?`, `err?`, `result-map`, `result-flat-map`, `result-map-error`, and `unwrap-or`; the representation is exactly a two-item `[:ok, VALUE]` or `[:err, VALUE]`, and malformed candidates error. Add `test.pp` exporting `expect-equal`, `expect-not-equal`, `expect-true`, `expect-false`, and `fail!`, with failures naming expected and actual pp values. Add `process.pp` exporting `run-result!` (argv proper list → `[:ok, {:exit -> INT, :out -> STRING, :err -> STRING}]` for exit 0 or `[:err, MAP]` otherwise) and `run-output!` (stdout for exit 0 or a located error containing status and stderr). Migrate `dune.pp`, `domain*.pp`, and `runtime.pp` to explicit exports, canonical effects, and these helpers.

9. Make completeness mechanically provable.
   - Extend `tools/fuzz.ml` full grammar to generate `EObserve` heads, persistent node/defnode, `with-caps`, sealed/unseal, fenced, probe registration/read, assert, reconcile, try/`<-`, collect, call spread, f-strings, exports, map patterns, and JSON/result values. Prevent references to undefined `g`; strip temporary pp-fuzzer paths before signature hashing so equivalent failures deduplicate. Every committed `fuzz-failures/` repro becomes a focused regression; once green, remove the generated failure corpus rather than retaining solved artifacts.
   - Add `tests/108-identity-collections.sh`, `109-observations.sh`, `110-effects.sh`, `111-modules-loader.sh`, `112-map-patterns.sh`, `113-project-cli.sh`, `114-stdlib-json.sh`, `115-test-command.sh`, and `116-cli-formatter.sh`. Extend `tests/054`/`055` for the canonical two-surface round trip and migrate every old spelling rather than testing compatibility. Increase CI’s full grammar count from 500 to 2000 and run the standalone kernel-property sweep.
   - Replace SPEC §0.1’s partial tier prose with the enforceable contract already distributed across the laws. The scripting tier is evaluation with no active persistent-node trace: it is uncached and may perform any granted effect. The node tier is the dynamic extent of forcing a `node`/`defnode`, including called closures: node arguments and referenced free variables are forced before keying; observations and custom-handler identities are traced; relative `$file`/`write!` use ephemeral scratch; `run-closed!` is allowed only when its provider classifies the complete request cacheable; `log!` occurs only on a miss; raw process/network, fenced actions, absolute/shared writes, and reconciliation applies are rejected; nested nodes contribute child traces; capability or sealed results are rejected before storage. Node-local ordinary lets remain lazy. Add one matrix test that exercises every allowed/rejected boundary, then mark the tier split holds.
   - After behavior is green, make the durable descriptions honest: remove LAW 10/20/35 caveats now closed or already implemented (`tests/097`, `106`, `107`); remove deleted `effect`, `.ppb`, `$glob`, raw-observation, old-effect, nonexistent LAW A5, nonexistent `ppc-*`, and deferred scheduler-budget references; remove the stale per-argument-handler aspiration rather than inventing a third handler class; update the closed sigil/effect/export/project/stdlib tables, issue #32 status, architecture ownership, and testing commands; regenerate SPEC surface tables and the manual site.
## Critical files & anchors

- `src/kernel/core_model.mli` — `pattern` and `expr`: the closed representation contract for `PMap`, `observation_kind`, `EObserve`, and `EExport`; every reader, printer, identity, quote, evaluator, and fuzzer slice follows it.
- `src/kernel/identity.ml` — `hash_value`/`hash_expr`: defines `=` and collection canonicalization’s identity order; any shortcut here can make cache keys unsound.
- `src/runtime/evaluator_scope.ml` — `with_caps`, `with_handlers`, `with_config`: current bodies invoke the caller continuation inside dynamic scope, the source of the LAW 10/27 contradiction.
- `src/runtime/evaluator_forms.ml` — `module_file`, `expressions_list`, `module_expr`, `merge_module`: owns explicit exports, import conflicts, project-module loading, and source-relative nested loads.
- `src/app/cli.ml` — raw command fields/flag table/help: one parser must own the project/test/fmt commands and the removal of broken aliases; `Command_project` consumes its typed variants.
- `src/runtime/macro.ml` and `src/runtime/session.ml` — sequential expansion and the session macro table become explicit module scopes; expansion order must precede node hashing.
- `src/runtime/observation.ml`, `src/kernel/cell.ml`, and their codecs — the single world-read implementation and the durable `Stat` trace cell must agree on observe/reobserve identity.
- `src/runtime/primitives.ml` and `src/runtime/evaluator_effects.ml` — public `!` values and default effect cases are one registry surface; remove old names rather than wrapping them.
- `src/runtime/island.ml`, new `src/app/project_manifest.ml`, and `src/app/command_project.ml` — pinned dependency identity, source-preserving manifest edits, and project execution stay separated.
- `src/frontend/printer_braces.ml`, `src/frontend/printer_sexpr.ml`, and `src/frontend/comments.ml` — canonical formatting/conversion must preserve comments, form count, and expression hashes without a second AST.
## Verification

Run from the repository root with the normal opam environment; no special environment variables are required unless a scenario below sets `HOME`.

1. During implementation, run the new focused scripts after their owning step:
   ```sh
   dune build
   bash tests/108-identity-collections.sh
   bash tests/109-observations.sh
   bash tests/110-effects.sh
   bash tests/111-modules-loader.sh
   bash tests/112-map-patterns.sh
   bash tests/113-project-cli.sh
   bash tests/114-stdlib-json.sh
   bash tests/115-test-command.sh
   bash tests/116-cli-formatter.sh
   ```
   Each script sources `tests/lib.sh`; expected result is only `ok` records and exit 0. `108` proves identity equality, rightmost map wins, set dedup/order, tagged exactness, thunk-hidden authority rejection, and v1 store invalidation. `109` covers all eight observations, absence/defaults, scratch reads, overlapping fs/secret grants, `Stat` codec round trips, and trace invalidation. `110` proves every new `!` value is higher-order, every old name is unbound, the tier allow/deny matrix, and dynamic-scope restoration/tail bounds. `111` covers export errors/collisions, private and exported macros, load sharing, project macros, hermetic expansion, and source-relative/std imports. `112` covers exact/ignored/bound map residuals and both surfaces. `113` covers init/add/update/remove/build, pin atomicity, and cache-only rebuild. `114` exercises every new stdlib export and every stated boundary/error. `115` covers discovery order, output/exit rules, symlink rejection, and per-file store isolation. `116` covers same-surface formatting, cross-surface stdout, comments, aliases, and CLI exit codes.

2. Pin the frontend failures directly:
   ```sh
   dune exec pp -- --check-roundtrip fuzz-failures/roundtrip_Invalid_argument-28efb937/min.ppl
   dune exec pp -- --check-roundtrip fuzz-failures/roundtrip_Failure_roundtrip__unprintable__cannot_break_bef-3a4876c4/min.ppl
   ```
   Both exit 0 with no output. `tests/054` and `055` then sweep every tracked `.pp`/`.ppl`, format each surface, convert between surfaces under the same logical source label, and assert equal form counts and hashes.

3. Exercise the new language paths through the binary, not library calls:
   ```sh
   tmp="$(mktemp -d)"
   HOME="$tmp/home" dune exec pp -- init "$tmp/app"
   HOME="$tmp/home" dune exec pp -- build --project "$tmp/app/project.pp"
   HOME="$tmp/home" dune exec pp -- test --project "$tmp/app/project.pp"
   printf '{"z":1,"a":[true,null,"x"]}' > "$tmp/data.json"
   HOME="$tmp/home" dune exec pp -- --grant "fs:$tmp:ro" -e 'print(value->json(json->value($file("'"$tmp"'/data.json"))))'
   rm -rf "$tmp"
   ```
   `init` creates exactly the four scaffold artifacts, `build` exits 0, `test` prints `PASS tests/project_test.pp` then `1 passed, 0 failed, 1 total`, and the JSON command prints `"{\"a\":[true,null,\"x\"],\"z\":1}"`. The project test script additionally adds a local `file:` island, updates it, builds from the cache after deleting the source, rejects a duplicate dependency, and proves a failed repin leaves `project.pp` byte-identical.

4. Exercise dynamic scope and modules with concrete regressions in `tests/110`/`111`: a `do` continuation after each of `with-caps`, `with-handler`, and `with-config` observes the outer scope; a 100,000-step tail recursion with the scope form in the tail path completes; an exception restores scope; nested source-relative imports work when invoked from another working directory; `import "std:list"` exposes only its export list; missing/duplicate/unknown exports and import collisions exit nonzero with located names.

5. Run all repository gates required by the touched evaluator, identity, and durable value contracts:
   ```sh
   dune build @architecture
   dune build @unit
   dune exec ./src/app/main.exe -- --check-kernel-props --seed 1 --count 3000
   dune runtest --force
   dune exec ./tools/fuzz.exe -- --grammar core --count 2000
   dune exec ./tools/fuzz.exe -- --grammar full --count 2000
   ```
   Every command exits 0. The full fuzzer must report no mismatch, crash, unprintable form, hash divergence, invalid generated binding, or soft failure outside its intentional error classes. Finally run `scripts/build-manual.sh`; every executable manual example and generated-surface drift check must pass.
## Assumptions & contingencies

- Exclude both `docs/PLAN-network-simulator.md` and GitHub issue #16 (CUE interop). Existing cluster/transport behavior remains in regression coverage, but this plan adds no simulator or external-language adapter.
- Keep `dune-project` and `src/kernel/version.ml` at `0.2.0-dev`; completion does not declare 1.0 compatibility.
- `project.pp` plus inline island pins deliberately replaces the rough backlog's “manifest + lockfile” pair: the source file is the manifest and its content pins are the lock. If an island URI cannot be pinned, `pp add`/`pp update` leaves the original manifest byte-for-byte unchanged and reports the resolver error.
- The absent `ppc-run`/`ppc-finish` implementation is stale prose, not a self-hosting-compiler requirement: no matching symbol exists in `src/`, `stdlib/`, tests, or tools, and DESIGN.md requires one evaluator.
- Canonical map/set ordering changes the durable value codec, so execution must bump the store marker to `pp-store 2`. Reuse `Store_layout.init`’s existing mismatch behavior exactly: wipe the versioned `Objects`, `Traces`, `Fenced_specs`, and `Procs` areas; retain raw blobs, the journal, and user source; rewrite `VERSION`; never decode v1 value objects as v2.
- `PP_STORE_ROOT` is an internal subprocess/test isolation control, not a language input and not a project manifest field. Normal invocations without it continue to use `~/.pp/store`.

## Remaining work at commit time

The map-pattern slice is complete and committed alongside this plan. The following approved work remains, in the order tracked by the completion checklist:

### Modules
- Remove parser extension fallthrough and ppb.

### Patterns and formatting
- Implement canonical comment-preserving formatter commands.

### Projects
- Define the canonical project module model.
- Decode and validate typed project manifests.
- Implement project init, dependency, and build commands.

### Project tests
- Discover and isolate project test files.
- Report deterministic project test results.

### Standard library
- Complete canonical list library exports.
- Complete map, vector, and set libraries.
- Complete string and path libraries.
- Implement the strict pure JSON codec.
- Complete result, test, and process libraries.

### Completeness
- Expand the full grammar and remove the repro corpus.
- Add focused regression scripts and CI gates.
- Codify complete scripting and node tiers.
- Update durable documentation and the generated manual.

### Verification
- Run focused scripts and the build.
- Pin frontend repros and surface sweeps.
- Smoke-test project and JSON workflows.
- Exercise scope and module regressions.
- Run the architecture suite, properties, fuzzers, and manual checks.

### Current verification note
- Map-pattern implementation is covered by tests/108-map-patterns.sh and the adjacent match tests.
- The pre-existing tests/084-match-sexpr-surface.sh still assumes the removed .ppb extension; updating that stale fixture belongs to the parser-extension cleanup item above.
