(* pp shared reader-level desugars (SPEC Appendix B).

   Every reader-level sugar whose OUTPUT participates in LAW-20 hashing lives
   here, so no reader may re-render it in its own notation. Most of these are
   shared by BOTH parsers (src/reader.ml, the s-expression surface;
   src/reader_braces.ml, the brace surface), so the two readers cannot drift:
   the block rule + its duplicate-definition check (LAW 4), the per-parameter
   type-check desugar (LAW 32), the `and`/`or` -> `if` desugar, and the
   `assert` -> `if`+`error` desugar (whose message string — including the
   s-expression rendering of the condition and the `at file:line` suffix — is
   part of the desugared expression and therefore of every enclosing hash;
   Appendix B §B.4).

   The `try`-block lowering is brace-surface-only (the s-expression surface has
   no `try` sugar); it lives here anyway because the brace reader must apply it
   in TWO contexts — direct code, building real AST, and inside `quasiquote{}`,
   building quoted list data — and [lower_try] is written once over a
   [try_builder] the caller supplies, so those two shapes cannot drift.

   [err] is each caller's own located-parse-error raiser, so error text keeps
   that reader's exact `msg at file:line` format (LAW 29). *)

open Types

(* Blocks (do bodies, multi-expression fn/def/let bodies, modules) give every
   def whole-block letrec* scope, so one name defined twice in a block is
   incoherent. Function defs keep their pre-existing shadowing latitude; any
   collision involving a VALUE def is rejected at read time. *)
let check_block_defs ~(err : string -> unit) (exprs : expr list) : expr list =
  let name_of = function
    | EDef (n, _, _) | EDefNode (n, _, _)
    | ELocated (_, (EDef (n, _, _) | EDefNode (n, _, _))) -> Some (n, false)
    | EDefValue (n, _) | ELocated (_, EDefValue (n, _)) -> Some (n, true)
    | _ -> None
  in
  let seen : (string, bool) Hashtbl.t = Hashtbl.create 8 in
  List.iter (fun e ->
    match name_of e with
    | None -> ()
    | Some (n, is_val) ->
        (match Hashtbl.find_opt seen n with
         | Some was_val when is_val || was_val ->
             err ("duplicate definition in block: " ^ n)
         | Some _ -> ()
         | None -> Hashtbl.add seen n is_val))
    exprs;
  exprs

(* Assemble a body from the expressions of a block, validating its defs.
   One statement -> the statement itself; several -> (do ...); zero -> (do). *)
let block_body ~(err : string -> unit) (exprs : expr list) : expr =
  match check_block_defs ~err exprs with
  | [b] -> b
  | bs -> EDo bs

(* Assemble a function's parameter names and body: each annotated parameter
   desugars into a located type check run ahead of the body — both backends
   compile/evaluate the shared desugared AST, so the checks are enforced
   identically (LAW 32). An optional return annotation wraps the body. *)
let assemble_fn_body locate (params : (string * expr option) list)
    (ret_ty : expr option) (body : expr) : string list * expr =
  let names = List.map fst params in
  let checks =
    List.filter_map (fun (p, tyo) ->
      match tyo with
      | Some ty -> Some (locate (ETyped (ESymbol p, ty)))
      | None -> None) params in
  let body' = match ret_ty with
    | Some ty -> locate (ETyped (body, ty))
    | None -> locate body in
  match checks with
  | [] -> (names, body')
  | _ -> (names, EDo (checks @ [body']))

(* (and exprs...) — short-circuiting AND. A right-associative infix chain
   `a and b and c` feeds this the same list and yields the identical EIf
   tree (Appendix B §B.2: the desugar erases the arity). *)
let desugar_and (exprs : expr list) : expr =
  let rec desugar = function
    | [] -> ELiteral (VBool true)
    | [e] -> e
    | e :: rest -> EIf (e, desugar rest, ELiteral (VBool false))
  in
  desugar exprs

(* (or exprs...) — short-circuiting OR. *)
let desugar_or (exprs : expr list) : expr =
  let rec desugar = function
    | [] -> ELiteral (VBool false)
    | [e] -> e
    | e :: rest -> EIf (e, ELiteral (VBool true), desugar rest)
  in
  desugar exprs

(* (assert cond [msg]) — a located runtime check: a false/nil condition
   raises `assertion failed: <form> at file:line` (or the custom message,
   location appended). Desugars to if+error so both backends enforce the
   shared AST identically. The message-less form renders the condition via
   quote_to_value/string_of_value — i.e. in AST (s-expression) notation in
   BOTH surfaces (Appendix B §B.4): the rendering is part of the hashed
   expression, so no reader may re-render it in its own notation. *)
let desugar_assert ~(file : string) ~(line : int)
    (cond : expr) (msg_opt : expr option) : expr =
  let loc_suffix = Printf.sprintf " at %s:%d" file line in
  let msg_expr = match msg_opt with
    | None ->
        ELiteral (VString ("assertion failed: "
                           ^ string_of_value (quote_to_value cond)
                           ^ loc_suffix))
    | Some m ->
        EApply (ESymbol "string-append", [m; ELiteral (VString loc_suffix)]) in
  EIf (cond, ELiteral VNil, EApply (ESymbol "error", [msg_expr]))

(* try { name <- expr; ...; final-expr } — brace-surface error propagation.
   A `name <- expr` (TryBind) unwraps [:ok, v] or short-circuits, propagating
   [:err, e]; any other statement (TryExpr) runs in sequence, and the last one
   is the block's result when every propagation succeeds. *)
type try_stmt = TryBind of string * expr | TryExpr of expr

(* How to build each node of the lowering. Two instances exist: the normal
   reader's (real AST nodes, [normal_try_builder] below) and the brace reader's
   quasiquote builder (quoted list data, built in reader_braces.ml where the
   qq_chain/qq_sym helpers live). [lower_try] walks the statements once against
   whichever builder it is given, so the direct and quasiquoted forms produce
   the SAME nested let/if shape by construction — the direct form as nodes, the
   quasiquoted form as the data that reconstructs those same nodes. *)
type try_builder = {
  t_ok_kw : expr;                          (* the :ok keyword *)
  t_sym   : string -> expr;                (* a bare symbol reference *)
  t_app   : string -> expr list -> expr;   (* (f args…) *)
  t_do    : expr list -> expr;             (* (do es…) *)
  t_let   : string -> expr -> expr -> expr;(* bind one name to a value in a body *)
  t_if    : expr -> expr -> expr -> expr;  (* a 3-arm if *)
}

let normal_try_builder : try_builder = {
  t_ok_kw = ELiteral (VKeyword "ok");
  t_sym   = (fun s -> ESymbol s);
  t_app   = (fun f args -> EApply (ESymbol f, args));
  t_do    = (fun es -> EDo es);
  t_let   = (fun name v body -> ELet ([name, v], body));
  t_if    = (fun c t e -> EIf (c, t, e));
}

(* Lower a try block to a nested if-chain. [fresh_var] supplies the temporary
   names; the caller owns the counter (reset once per top-level form) so a
   form's LAW-20 hash depends only on the form, not on how many try blocks
   preceded it — and must be invoked here, inline at parse time, in this
   top-down traversal, never deferred to a later whole-AST pass. *)
let lower_try ~(fresh_var : unit -> string) (b : try_builder)
    (stmts : try_stmt list) : expr =
  let car_of e = b.t_app "car" [e] in
  let cdr_of e = b.t_app "cdr" [e] in
  let rec build = function
    | [] -> b.t_ok_kw                      (* default: :ok (nil result) *)
    | [TryExpr e] -> e
    | TryExpr e :: rest -> b.t_do [e; build rest]
    | TryBind (name, rhs) :: rest ->
        let tmp = fresh_var () in
        let tmp_sym = b.t_sym tmp in
        let ok_branch = b.t_let name (car_of (cdr_of tmp_sym)) (build rest) in
        let err_branch = tmp_sym in
        b.t_let tmp rhs
          (b.t_if (b.t_app "=" [car_of tmp_sym; b.t_ok_kw]) ok_branch err_branch)
  in
  build stmts
