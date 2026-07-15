(* pp macro expansion — defmacro (M3, D10's promise)

   Architecture (LAW 20/36): expansion is the ONE shared step both backends
   pass through before their own machinery ever sees a form — hash_expr
   (the tree-walker's node key) and the compiler both operate on ALREADY-
   EXPANDED ASTs, so LAW 20 ("the code hash must hash the expanded form")
   needs no change anywhere else: it is true by construction, because
   neither node_key_of/vm_node_key nor compile_expr can ever observe a macro
   call — it never survives past this module.

   `defmacro` is deliberately NOT a reader-level construct (no entry in
   reader.ml's parse_special_form table): `(defmacro (name params...)
   body...)` parses as an ordinary application — EApply (ESymbol "defmacro",
   ...) — exactly like any unrecognized head symbol (reader.ml
   parse_special_form's fallthrough case). This module recognizes that SHAPE
   at the expansion boundary, never in the reader, so the .ppc/compiler
   paths stay untouched and honest: compiler.ml, vm.ml's opcodes, and
   node_key_of/vm_node_key have no idea macros exist — they only ever see
   the expr trees this module already rewrote.

   Scope/phasing (documented decisions — MASTERPLAN M3 poses these as open
   questions; these are the answers, chosen for the simplest sound rule):

   - A `defmacro` is recognized ONLY as a direct element of the outermost
     list handed to a top-level driver — a file's or REPL input's top-level
     forms, sequentially, exactly like a value def (SPEC: the top level is
     sequential). A macro used before its own definition sees an ordinary
     unbound-symbol/application error, never a special "forward reference"
     diagnostic — same as calling an undefined function.
   - `load`ed files share the SAME (global, mutable) macro table as their
     loader: `load` is sequential evaluation, so a macro the loaded file
     defines is visible to the rest of the LOADING file's forms that follow
     the `load`, and a loader's earlier macros are visible inside the loaded
     file. Every call site that turns a fresh `Reader.read_string` form list
     into something a backend will see routes through
     `expand_toplevel_list` (or, from evaluator.ml, which cannot depend on
     this module without a cycle, through `Primitives.expand_toplevel_ref`,
     which this module installs below).
   - `defmacro` is NOT specially recognized inside `do`/`module`/`fn`/`def`/
     `node`/`delay`/... bodies, answering MASTERPLAN's "(and in modules?)"
     question NO: only the true top level (of a file, a REPL input, or a
     loaded file) counts. Anywhere else in the tree, a raw `(defmacro ...)`
     is simply left alone by the expander below (its own head symbol,
     "defmacro", is never itself a registered macro), so it reaches
     eval/compile as an ordinary application of an unbound symbol and fails
     with the exact same "unbound symbol: defmacro" every other stray call
     would. This is the simplest sound rule for MASTERPLAN's explicit ask
     ("macro definitions inside node bodies: error") — it falls out for
     free, with no special-cased detection code, and it generalizes to
     every other non-top-level position instead of just nodes. (Nodes
     specifically: a node's body is deferred/cached across process runs,
     and letting a `defmacro` inside it register into the ambient,
     eagerly-populated-at-expansion-time table would be confusing —
     whether the macro "exists" would look like it depends on whether the
     node ever forces, when in truth expansion is unconditional and
     ahead-of-time. Refusing it entirely avoids the footgun.)

   Hygiene (documented, not automatic — MASTERPLAN M3 does not require full
   hygiene): macros are UNHYGIENIC. A variable a macro's expansion
   INTRODUCES can capture, or be captured by, a binding at the call site,
   exactly as in any Lisp-1 macro system without a hygiene pass. The
   discipline is manual: call `(gensym ["prefix"])` (primitives.ml) for
   every binding a macro introduces; splice the CALLER's own forms in via
   quasiquote/unquote verbatim, never renamed — they are the caller's
   syntax, not the macro's. *)

open Types

(* name -> (parameter names, body expr). Persistent, mutable, shared by both
   backends (the whole point of a single expansion point) — reset at the
   start of every fresh run (Evaluator.init, wired below), exactly like
   thunk_store/handler_stack/etc. Fixed-arity only: no variadic/rest-param
   macros (pp functions do not have rest params either). *)
let macro_table : (string, string list * expr) Hashtbl.t = Hashtbl.create 16

let reset () : unit = Hashtbl.clear macro_table

(* A guard against a macro whose expansion never stabilizes (each expansion
   producing another use of the same or another macro, forever). Expansion
   is a static, ahead-of-time pass over the program text — a
   non-terminating macro would hang the EXPANDER itself, not overflow a
   runtime stack the way non-terminating recursive pp CODE would, so this
   is a plain counter, reset per top-level list. *)
let max_expansions = 100_000
let expansion_count = ref 0

let macro_error (name : string) (msg : string) : 'a =
  failwith (Printf.sprintf "macro '%s': %s" name msg)

(* Attach [loc] to the TOP of [e] — but only if [e] isn't already ELocated.
   Both backends' top-level-form consumers (evaluator.ml eval_expressions'
   `step`, compiler.ml compile_program's `compile_all`) unwrap exactly ONE
   ELocated layer before pattern-matching on EDef/EDefValue/etc. to decide
   whether the form binds something; a DOUBLE wrap here would leave the
   inner EDef invisible past that one unwrap, so the closure would be built
   and then silently discarded instead of bound (tree-walker) — or, in the
   compiler, matched by neither the EDef arm nor by anything that consumes
   its own STORE_GLOBAL, so an extra POP would corrupt the operand stack.
   apply_macro already wraps its OWN result in ELocated once (so a nested
   macro-call site keeps a location even when the ENCLOSING form is not
   itself the macro call); this function's job is only to add a wrap when
   there isn't one yet — e.g. an ordinary (non-macro-call) top-level form
   whose subexpressions were expanded without ever touching its own top. *)
let relocate (loc : (string * int) option) (e : expr) : expr =
  match e with
  | ELocated _ -> e
  | _ -> (match loc with Some l -> ELocated (l, e) | None -> e)

(* Recognize `(defmacro (name params...) body...)`. Any OTHER shape headed
   by the symbol "defmacro" — a malformed parameter list, no body, or a
   name position that parsed as something other than an application because
   it collided with a reader special-form keyword, e.g. `(defmacro (if a)
   ...)` parses `(if a)` as EIf, not EApply — is a malformed-definition
   error, not silently ignored: better to fail loudly at the definition
   site than produce a confusing "unbound symbol: defmacro" several forms
   later. *)
let match_defmacro (e : expr) : (string * string list * expr) option =
  match e with
  | EApply (ESymbol "defmacro", head :: body_exprs) ->
      let name, param_exprs =
        match head with
        | EApply (ESymbol n, ps) -> (n, ps)
        | _ -> failwith "defmacro: expected (defmacro (name params...) body...)"
      in
      if body_exprs = [] then
        failwith (Printf.sprintf "defmacro: '%s' has no body" name);
      let params = List.map (function
        | ESymbol s -> s
        | _ -> failwith (Printf.sprintf
                 "defmacro: '%s': parameters must be symbols" name))
        param_exprs
      in
      let body = match body_exprs with [b] -> b | bs -> EDo bs in
      Some (name, params, body)
  | EApply (ESymbol "defmacro", []) ->
      failwith "defmacro: expected (defmacro (name params...) body...)"
  | _ -> None

(* Apply a macro to its (unevaluated!) argument FORMS: quote each form to a
   value (Types.quote_to_value — the total base, D10/D19), bind the macro's
   parameters to those values (plain values, not thunks — they are already
   fully-realized quoted data, and the macro body is expansion-time code,
   not the program proper), run the body through the TREE-WALKER (LAW 36:
   "the tree-walker is the oracle" — expansion is backend-independent by
   construction, since it happens before either backend is even chosen),
   force the result deeply (a macro body may itself end in a delay/thunked
   tail), and convert the resulting value back to syntax.

   The macro body's environment is Primitives.initial_env () (builtins:
   cons, list, map, gensym, quasiquote, ...) extended with exactly its own
   parameters — NOT the calling program's top-level bindings. This is a
   deliberate, documented restriction: a macro cannot close over a
   user-defined helper function from the surrounding file. Threading "the
   current top-level environment" through here would mean reconciling the
   tree-walker's env-chain representation with the VM's globals-table one at
   the one point that is supposed to be backend-agnostic — exactly the
   seam LAW 36 exists to keep out of this module. Macros compose via
   ordinary data-structure primitives instead (the same restriction Racket's
   phase separation and Scheme's begin-for-syntax impose for the same
   reason). *)
let apply_macro ~(name : string) ~(params : string list) ~(body : expr)
    ~(args : expr list) ~(loc : (string * int) option) : expr =
  incr expansion_count;
  if !expansion_count > max_expansions then
    macro_error name "expansion did not terminate (possible non-terminating macro)";
  if List.length args <> List.length params then
    macro_error name
      (Printf.sprintf "expected %d argument(s), got %d"
         (List.length params) (List.length args));
  let arg_values = List.map Types.quote_to_value args in
  let macro_env =
    List.fold_left2 (fun e p v -> Types.extend_env e p v)
      (Primitives.initial_env ()) params arg_values
  in
  let result =
    try Primitives.force_deep (Evaluator.eval body macro_env)
    with
    | Failure msg -> macro_error name msg
    | Types.Capability_error msg -> macro_error name msg
  in
  let expanded =
    try Types.value_to_expr result
    with Failure msg -> macro_error name msg
  in
  relocate loc expanded

(* Recursively expand macro CALLS anywhere in an already-parsed expr tree,
   under the CURRENT macro table — used both for ordinary (non-defmacro)
   top-level forms and for every nested position within them (a function
   body, an if-branch, a node body, a quasiquote-embedded unquote, ...).
   Quoted data (EQuote) is left completely alone: '(unless x 1 2) is DATA,
   never a call, so it must never be expanded — quasiquote's own reader
   desugaring already keeps a bare template symbol as EQuote (ESymbol _),
   never ESymbol, for exactly this reason (reader.ml parse_qq_expr's atom
   fallthrough).

   [loc] is the innermost enclosing source location seen so far (best-
   effort LAW 29 preservation, MASTERPLAN M3 point 6): re-stamped whenever
   the walk passes an ELocated node (the reader, and assemble_fn_body,
   attach these at more than just the top level — parameter type checks,
   typed bodies), and attached to the top of every expansion so an error
   inside expanded code still cites a real file:line — the macro CALL
   site's, not the macro DEFINITION's. *)
let rec expand_expr (loc : (string * int) option) (e : expr) : expr =
  match e with
  | ELocated (l, inner) -> ELocated (l, expand_expr (Some l) inner)
  | EApply (ESymbol name, args) when Hashtbl.mem macro_table name ->
      let (params, body) = Hashtbl.find macro_table name in
      expand_expr loc (apply_macro ~name ~params ~body ~args ~loc)
  | EApply (fn, args) -> EApply (expand_expr loc fn, List.map (expand_expr loc) args)
  | EQuote _ -> e
  | ELiteral _ | ESymbol _ -> e
  | EIf (c, t, f) -> EIf (expand_expr loc c, expand_expr loc t, expand_expr loc f)
  | ELet (binds, body) ->
      ELet (List.map (fun (n, e) -> (n, expand_expr loc e)) binds, expand_expr loc body)
  | ELetStar (binds, body) ->
      ELetStar (List.map (fun (n, e) -> (n, expand_expr loc e)) binds, expand_expr loc body)
  | EFn (params, body) -> EFn (params, expand_expr loc body)
  | EForce e -> EForce (expand_expr loc e)
  | EDelay e -> EDelay (expand_expr loc e)
  | ENode e -> ENode (expand_expr loc e)
  | EDefNode (name, params, body) -> EDefNode (name, params, expand_expr loc body)
  | EDef (name, params, body) -> EDef (name, params, expand_expr loc body)
  | EDefValue (name, e) -> EDefValue (name, expand_expr loc e)
  | EDo exprs -> EDo (List.map (expand_expr loc) exprs)
  | EModule exprs -> EModule (List.map (expand_expr loc) exprs)
  | EWithCaps (c, b) -> EWithCaps (expand_expr loc c, expand_expr loc b)
  | EPerform (n, args) -> EPerform (n, List.map (expand_expr loc) args)
  | EWithHandler (hs, b) ->
      EWithHandler (List.map (fun (n, h) -> (n, expand_expr loc h)) hs, expand_expr loc b)
  | EImport e -> EImport (expand_expr loc e)
  | ELoad _ | ELoadModule _ | EIsland _ -> e
  | EWithConfig (m, b) -> EWithConfig (expand_expr loc m, expand_expr loc b)
  | EConfig (k, d) -> EConfig (expand_expr loc k, Option.map (expand_expr loc) d)
  | ETyped (e, ty) -> ETyped (expand_expr loc e, ty)
  | EMatch (scrutinee, arms) ->
      EMatch (expand_expr loc scrutinee,
              List.map (fun (p, guard, body) ->
                (p, Option.map (expand_expr loc) guard, expand_expr loc body)) arms)

(* The shared top-level driver hook: every call site that turns a fresh
   `Reader.read_string` result into a list a backend is about to eval/compile
   MUST pass it through here first (repl.ml's execute_string/
   execute_string_bytecode/repl_loop, vm.ml's LOAD_FILE and
   eval_module_from, evaluator.ml's ELoad/eval_module_file via
   Primitives.expand_toplevel_ref). Walks the list IN ORDER, updating the
   global macro table as `defmacro` forms are found (so later forms — in
   THIS list, or a subsequent call, e.g. after a `load` returns — see them),
   and expanding every other form. A recognized `defmacro` is replaced by
   `(quote name)` (evaluates to the macro's own name as a symbol — mirrors
   `def` returning its closure), so the 1:1 form-per-value contract every
   top-level driver relies on (REPL/execute_string's `List.map`) is
   unaffected. *)
let expand_toplevel_list (exprs : expr list) : expr list =
  expansion_count := 0;
  List.map (fun e ->
    let loc, inner = match e with ELocated (l, i) -> (Some l, i) | _ -> (None, e) in
    match match_defmacro inner with
    | Some (name, params, body) ->
        Hashtbl.replace macro_table name (params, body);
        relocate loc (EQuote (ESymbol name))
    | None ->
        relocate loc (expand_expr loc inner))
    exprs

let () =
  Backend.r.expand_toplevel <- expand_toplevel_list;
  Backend.r.macro_reset <- reset
