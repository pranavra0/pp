# pp: correctness debt and node-application keying

Stack-safe evaluator is deferred to a follow-up design pass; this branch contains the three items that are decision-complete now.

## Context

Cut a branch from current `main` and land three related fixes. A fourth item is deferred because the first detailed design pass had correctness gaps that must be closed before it can be implemented safely.

1. **D23** — VM module bodies see enclosing top-level `let` bindings; the tree-walker oracle does not. Close the divergence.
2. **D24** — `with-handler`/`with-config` exception safety is already implemented in both backends (both use `try/with` around the body region). The remaining work is to add differential tests and retire the stale STATUS/PLAN/compiler-comment entries.
3. **Node application keying (SPEC LAW 6/20)** — `defnode f(x) { body }` is currently a plain closure. Make applying it create a persistent node thunk keyed on the argument value hashes, so `map(fn(src) { compile-file(src) }, sources)` caches each compilation independently under an aggregator.
4. **Stack-safe evaluator (SPEC LAW 11)** — deferred. A design review found that converting the tree-walker to a heap-allocated abstract machine requires carefully matching every existing semantic detail (symbol forcing, thunk backpatching in `let`, `let*` thunk binding, effect handler lookup, `config` key handling, etc.) before it can be implemented without silently changing behavior. It will land on a follow-up branch once a corrected machine design is written.

This branch ends with `dune runtest`, the fuzzer, and the new tests green.

## Approach

### 0. Branch

Create and check out `feat/correctness-node-key` from the current `main`. All commits on this branch use Conventional Commits (`fix:`, `feat:`, `test:`, `refactor:`) with no trailers.

### 1. D23: VM module scope leak

Make inline `module { ... }` run with isolated globals, matching `eval_module_from` for file-loaded modules.

1. **Add `CALL_MODULE` opcode** in `src/types.ml` (`opcode` variant). It takes no operands; the stack holds the 0-argument module constructor closure.
2. **Implement `CALL_MODULE` in `src/vm.ml`** at the top of the main `run` loop, before `CALL`:
   - Pop the closure; assert it is `VClosure` with `nparams = 0`.
   - `let saved = Hashtbl.copy globals in`
   - `Hashtbl.clear globals;` then seed with `Primitives.initial_env ()` bindings.
   - Run the closure via `try run_isolated c.vm_bc c.vm_offset (build_call_frames c []) with e -> Hashtbl.clear globals; Hashtbl.iter (Hashtbl.add globals) saved; raise e`.
   - The result must be `VEnvMap bindings`; assert this and raise a clear `VM: module body did not return a module value` otherwise.
   - Collect `new_bindings` as those not in `initial_env ().bindings`, exactly like `eval_module_from`.
   - `Hashtbl.clear globals; Hashtbl.iter (Hashtbl.add globals) saved;`
   - Push `VEnvMap (List.rev new_bindings)`.
3. **Change `EModule` compilation in `src/compiler.ml`** to emit `CALL_MODULE` instead of `CALL 0` after `MAKE_CLOSURE (body_start, 0)`.
4. **Add a differential test** in `tests/039b-vm-module-scope.sh` covering:
   - Top-level `let x = 1` then `module M { def y = x }` → both backends error with `unbound symbol: x`.
   - A module inside a `do` block: `let z = 1; do { module N { def w = z } }` → error.
   - A module inside a function: `def f() { let z = 1; module N { def w = z } }` → error when `f()` is called.
   - Nested inline modules: `module Outer { def a = 1; module Inner { def b = a } }` → `a` is visible because it is defined inside the same isolated module scope.
   - `EImport` inside a module still merges the imported module's exports into the importing module's scope.
   Keep the existing D22 cases in `tests/039-vm-global-scope.pp` untouched.

The two file-loaded module paths (`LOAD_MODULE_FILE`, `ISLAND`) continue to use `eval_module_from`; no change needed there.

### 2. D24: exception-safe dynamic extent (verification and bookkeeping)

Both backends already wrap `with-handler` and `with-config` bodies in `try/with` (tree-walker `evaluator.ml` lines 529 and 635; VM `src/vm.ml` lines 345 and 487). The work is to prove it and clean up stale text.

1. **Add a differential test** in `tests/079-with-handlers.sh` (or a new `tests/079b-with-handler-exception.sh`) using a piped REPL session:
   - Install a handler inside `with-handler`.
   - Raise an error inside the body.
   - After the error, perform the same effect at top level and verify it uses the *outer* handler (builtin), not the leaked inner one.
   - Do the same for `with-config` (install config, raise, read config afterward; must see the outer config).
2. **Update stale prose**:
   - In `docs/STATUS.md` line 696, mark D24 `Fixed` and describe the `try/with` region pattern.
   - In `docs/PLAN.md` Part 0, remove the D24 bullet.
   - In `src/compiler.ml` line 324, rewrite the comment that still refers to "flat ENTER/EXIT opcode pairs" to state the current `try/with`-region design.

### 3. Node application keying (LAW 6/20)

Make `defnode f(x) { body }` evaluate/compile to a constructor that returns a persistent node thunk keyed on argument values.

#### Tree-walker change

In every place that builds a closure for `EDefNode`, use `ENode body` as the closure body instead of `body`:

- `src/evaluator.ml` line 431 (`eval_tail` top-level case):
  ```ocaml
  | EDefNode (name, params, body) ->
      k (make_closure ~name:(Some name) params (ENode body) (ref env))
  ```
- `src/evaluator.ml` lines 455-457 (`EDo` block fold):
  ```ocaml
  let closure = make_closure ~name:(Some name) params (ENode body) env_ref in
  ```
- `src/evaluator.ml` lines 581-583 (`EModule` block fold): same change.
- `src/evaluator.ml` lines 933-935 (`eval_expressions` top-level driver): same change.

Rationale: `apply_tail` extends the captured env with `params=args` and then evaluates `ENode body`. `ENode` creates a persistent thunk with `thunk_expr = body` and `thunk_env = env + params=args`. `node_key_of` hashes `body` plus the free variables of `body` forced in that env; since `body` references the parameters as free names, the argument value hashes become part of the node key.

#### Compiler/VM change

Add a helper that emits a closure whose body is a `MAKE_NODE` region. When the closure is called, the args occupy the local frame, so the `MAKE_NODE` captures them as free-variable values.

1. **Add `emit_node_constructor_region` in `src/compiler.ml`** after `emit_node_region`:
   ```ocaml
   and emit_node_constructor_region ?(name=None) (st : comp_state) (params : string list) (body : expr) : int =
     let jmp_idx = current_offset st in
     emit st (JUMP 0);
     let ctor_body_start = current_offset st in
     let saved_cenv = st.cenv in
     st.cenv <- params :: st.cenv;
     ignore (emit_node_region st body);
     emit st RETURN;
     st.cenv <- saved_cenv;
     backpatch_jump st jmp_idx;
     Hashtbl.add st.nparams_of ctor_body_start (List.length params);
     Hashtbl.add st.param_names_of ctor_body_start params;
     (match name with Some n -> Hashtbl.add st.closure_names_of ctor_body_start n | None -> ());
     emit st (MAKE_CLOSURE (ctor_body_start, List.length params));
     ctor_body_start
   ```
2. **Split the combined `EDef`/`EDefNode` branches and replace only the `EDefNode` arms** with `emit_node_constructor_region`:
   - `src/compiler.ml` top-level `compile_expr`: split the `| EDef (name, params, body) | EDefNode (name, params, body) ->` branch into two separate branches. `EDef` keeps `emit_closure_region`; `EDefNode` uses `emit_node_constructor_region ~name:(Some name) st params body`, then `STORE_GLOBAL` and optional `LOAD_GLOBAL` exactly as `EDef` does.
   - `src/compiler.ml` `EDo` `compile_subs`: split the combined `EDef`/`EDefNode` case. `EDef` keeps `emit_closure_region` and `STORE_LOCAL di.slot`; `EDefNode` uses `emit_node_constructor_region ~name:(Some name) st params body` and `STORE_LOCAL di.slot`.
   - `src/compiler.ml` `EModule` body compiler: split the combined `EDef`/`EDefNode` case in the same way. `EDef` keeps `emit_closure_region`; `EDefNode` uses `emit_node_constructor_region`.
3. **No VM apply-path change is needed**: the constructor is an ordinary closure; its body executes `MAKE_NODE` and returns the thunk.

#### Tests

Add `tests/011b-node-application-keying.sh`:
- Define `defnode inc(x) { x + 1 }`.
- Call `inc(5)` and `inc(6)`; force both and check the results.
- Use `pp why` to show that the two calls have different node keys (a miss for the second call).
- Call `inc(5)` again and verify it hits.
- Define `defnode const(a, b) { a }`; call with `const(1, 2)` and `const(1, 3)` and verify both hit the same key (argument `b` is unused and therefore not a free var of the body, so only `a`'s hash matters).
- Define `defnode cap(x) { y }` inside a `let (y = 42) { ... }` block; verify `cap(1)` and `cap(2)` hit the same key because only the captured `y` hash matters, and that a different `y` produces a different key.
- Define `defnode nested(x) { x }` inside a `do` block and inside a `module` and verify both produce correct node keys differentially.
- Add a differential assertion that tree-walker and VM produce identical values and identical `pp why` output.

### 4. Stack-safe evaluator (deferred to a follow-up branch)

A design review of the first abstract-machine pass found correctness gaps that must be closed before the refactor can land without silently changing language semantics:

- Symbol lookup, `if` conditions, and function arguments must be **forced** before use, matching the current strict call-by-value evaluator.
- `ELet` mutual bindings must **backpatch** each thunk's `thunk_env` to the mutual environment so each RHS can see the others.
- `ELet*` must bind **content-addressed thunks**, not evaluated values, preserving the existing laziness and hashing contract.
- `EPerform` must record the handler observation and use `Dynamic_scope.Lookup_handler`, not a symbol lookup.
- `EWithHandler` must evaluate each handler expression to a closure and build a real handler table.
- `EConfig` must carry the forced key through the continuation frame and call `Dynamic_scope.config_lookup` correctly.

These are all fixable, but they show that the abstract-machine design must be written form-by-form against the current `eval_tail` semantics rather than sketched at a high level. The risk of silently changing behavior is too high to include in this branch.

**Decision:** this branch lands D23, D24, and node-application keying only. A follow-up branch `feat/stack-safe-evaluator` will carry LAW 11 with a corrected, form-by-form abstract-machine design and the four deep-recursion tests (currently the tree-walker crashes on these while the VM succeeds):

```pp
# tests/087-deep-recursion.pp — tail recursion
def sum(n, acc) { if n = 0 { acc } else { sum(n - 1, acc + n) } }
print(sum(100000, 0))

# tests/087-deep-recursion-non-tail.pp — non-tail recursion
def count(n) { if n = 0 { 0 } else { 1 + count(n - 1) } }
print(count(100000))

# tests/087-deep-recursion-mutual.pp — mutual recursion
def even?(n) { if n = 0 { true } else { odd?(n - 1) } }
def odd?(n)  { if n = 0 { false } else { even?(n - 1) } }
print(even?(100000))

# tests/087-deep-recursion-effects.pp — deep recursion under handlers
with { handlers: { :inc -> fn(n) { n + 1 } } } {
  def rec(n) { if n = 0 { 0 } else { perform inc(1) + rec(n - 1) } }
  print(rec(100000))
}
```

All four must eventually produce identical output in tree-walker and VM with no `Stack_overflow` or `Out_of_memory`.

## Critical files & anchors

| File | Anchor | Why |
|---|---|---|
| `src/vm.ml:310-500` | `WITH_CAPS`, `WITH_HANDLER`, `WITH_CONFIG`, `MAKE_MODULE`, `CALL` | D24 already fixed here; D23 needs `CALL_MODULE` near `CALL`. |
| `src/compiler.ml:119-183` | `emit_node_region`, `emit_closure_region`, `resolve` | Node constructor emission reuses these helpers. |
| `src/compiler.ml:200-473` | `ELet`, `EDefNode`, `EDo`, `EModule` | D23 leaks via `STORE_GLOBAL`; node keying changes the `EDefNode` arms. |
| `src/evaluator.ml:419-460` | `EDefNode`, `EDo` fold | Tree-walker node constructor change is here. |
| `src/evaluator.ml:670-763` | `apply_tail`, `trampoline_force` | Node constructor application flows through here. |

## Verification

Run these after every commit group:

```sh
# Build and differential suite
dune build
dune runtest

# Fuzzer (slow; run at least once before final push)
dune exec ./tools/fuzz.exe -- --grammar full

# New/existing targeted tests
pp --diff tests/039b-vm-module-scope.sh
pp --diff tests/011b-node-application-keying.sh
pp --diff tests/079-with-handlers.sh
```

For `tests/011b-node-application-keying.sh`, assert:
- `inc(5)` → `6`, `inc(6)` → `7`.
- Second `inc(5)` is a cache hit (`pp why` shows "hit").
- `const(1, 2)` and `const(1, 3)` share one node key.
- `cap(1)` and `cap(2)` with a captured `y` share one node key; a different `y` gives a different key.
- `nested` inside `do` and `module` both work differentially.

For `tests/039b-vm-module-scope.sh`, assert:
- Top-level `let` does not leak into a module body in either backend.
- `do` and function scopes do not leak into a module body.
- Nested inline modules share their own isolated scope.
- `EImport` inside a module still merges exports.

## Assumptions & contingencies

- **This branch contains three items only.** Stack-safety is deferred to a follow-up branch once a corrected abstract-machine design is written.
- **VM stays the oracle's follower.** Any tree-walker change that changes observable output must be mirrored in the VM/compiler so `--diff` stays green.
- **D24 code already matches design.** If the new tests reveal a remaining exception leak, fix the specific opcode handler before updating STATUS.md.
- **No `.ppc` persistence.** Adding `CALL_MODULE` changes the in-memory opcode enum; `.ppc` is documented as unused, so no migration is needed.
- **Conventional Commits.** Every commit on the branch is one of `fix:`, `feat:`, `test:`, `refactor:` with a single lowercase sentence and no trailers.
