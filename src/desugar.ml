(* pp shared reader-level desugars (SPEC Appendix B).

   Every reader-level sugar whose OUTPUT participates in LAW-20 hashing lives
   here, downstream of BOTH parsers (src/reader.ml, the s-expression surface;
   src/reader_braces.ml, the brace surface), so the two readers cannot drift:
   the block rule + its duplicate-definition check (LAW 4), the per-parameter
   type-check desugar (LAW 32), the `and`/`or` -> `if` desugar, and the
   `assert` -> `if`+`error` desugar (whose message string — including the
   s-expression rendering of the condition and the `at file:line` suffix — is
   part of the desugared expression and therefore of every enclosing hash;
   Appendix B §B.4).

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
