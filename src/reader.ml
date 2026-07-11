(* pp reader — s-expression parser with rich literals *)

open Types

(* ---- Lexer ---- *)

type token =
  | TokLParen | TokRParen
  | TokLBracket | TokRBracket
  | TokLBrace | TokRBrace
  | TokSharpLBrace
  | TokQuote | TokQuasiquote | TokUnquote | TokUnquoteSplicing
  | TokDot | TokColon
  | TokString of string
  | TokNumber of int
  | TokFloat of float
  | TokSymbol of string
  | TokKeyword of string
  | TokIsland of string
  | TokEOF

let string_of_token t =
  match t with
  | TokLParen -> "(" | TokRParen -> ")" | TokLBracket -> "["
  | TokRBracket -> "]" | TokLBrace -> "{" | TokRBrace -> "}"
  | TokSharpLBrace -> "#{" | TokQuote -> "'" | TokQuasiquote -> "`"
  | TokUnquote -> "," | TokUnquoteSplicing -> ",@" | TokDot -> "." | TokColon -> ":"
  | TokString s -> Printf.sprintf "\"%s\"" s
  | TokNumber n -> string_of_int n
  | TokFloat f -> string_of_float f
  | TokSymbol s -> s
  | TokKeyword k -> ":" ^ k
  | TokIsland s -> "<" ^ s ^ ">"
  | TokEOF -> "<eof>"

(* Line tracking: updated during lexing so each token can record its source line. *)
let lex_line = ref 1
let current_file = ref ""

let lex_error line msg =
  failwith (Printf.sprintf "%s at %s:%d" msg !current_file line)

(* Lex a string into a list of (token, start_line) pairs. *)
let lex (input : string) : (token * int) list =
  let len = String.length input in
  let pos = ref 0 in
  let tokens = ref [] in

  let add t = tokens := (t, !lex_line) :: !tokens in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let advance () = pos := !pos + 1 in

  let rec next_delim () =
    match peek () with
    | None -> ()
    | Some c ->
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' then
        (if c = '\n' then incr lex_line; advance (); next_delim ())
      else if c = ';' then
        (advance (); skip_comment ())
      else
        (token (); next_delim ())

  and skip_comment () =
    match peek () with
    | Some '\n' -> incr lex_line; advance (); next_delim ()
    | Some '\r' | None -> advance (); next_delim ()
    | Some _ -> advance (); skip_comment ()

  and token () =
    match peek () with
    | None -> add TokEOF
    | Some '(' -> add TokLParen; advance ()
    | Some ')' -> add TokRParen; advance ()
    | Some '[' -> add TokLBracket; advance ()
    | Some ']' -> add TokRBracket; advance ()
    | Some '{' -> add TokLBrace; advance ()
    | Some '}' -> add TokRBrace; advance ()
    | Some '<' ->
        advance ();
        (match peek () with
         | Some '=' -> advance (); add (TokSymbol "<=")
         | Some c when (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ->
             read_island_rest ()
         | _ -> add (TokSymbol "<"))
    | Some '\'' -> add TokQuote; advance ()
    | Some '`' -> add TokQuasiquote; advance ()
    | Some ',' ->
        advance ();
        (match peek () with Some '@' -> advance (); add TokUnquoteSplicing | _ -> add TokUnquote)
    | Some '#' ->
        advance ();
        (match peek () with
         | Some '{' -> advance (); add TokSharpLBrace
         | _ -> lex_error !lex_line "unexpected character after #")
    | Some '"' -> read_string ()
    | Some '-' ->
        let next = if !pos + 1 < len then Some input.[!pos + 1] else None in
        let after = if !pos + 2 < len then Some input.[!pos + 2] else None in
        (match next with
         | Some c when c >= '0' && c <= '9' -> read_number ()
         | Some '.' when (match after with
                          | Some d -> d >= '0' && d <= '9'
                          | None -> false) -> read_number ()
         | _ -> read_symbol ())
    | Some c when c >= '0' && c <= '9' -> read_number ()
    | Some ':' -> read_keyword ()
    | Some _ -> read_symbol ()

  and read_string () =
    assert (peek () = Some '"'); advance ();
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | None -> lex_error !lex_line "unterminated string"
      | Some '"' -> advance (); add (TokString (Buffer.contents buf))
      | Some '\\' ->
          advance ();
          (match peek () with
           | Some 'n' -> advance (); Buffer.add_char buf '\n'; loop ()
           | Some 't' -> advance (); Buffer.add_char buf '\t'; loop ()
           | Some '\\' -> advance (); Buffer.add_char buf '\\'; loop ()
           | Some '"' -> advance (); Buffer.add_char buf '"'; loop ()
           | Some c -> advance (); Buffer.add_char buf c; loop ()
           | None -> lex_error !lex_line "unterminated escape")
      | Some c ->
          if c = '\n' then incr lex_line;
          advance ();
          Buffer.add_char buf c;
          loop ()
    in loop ()

  and read_number () =
    let buf = Buffer.create 8 in
    let is_float = ref false in
    let rec loop () =
      match peek () with
      | Some '.' when not !is_float ->
          is_float := true; Buffer.add_char buf '.'; advance (); loop ()
      | Some c when (c >= '0' && c <= '9') || c = '-' || c = 'e' || c = 'E' || c = '+' ->
          Buffer.add_char buf c; advance (); loop ()
      | _ -> ()
    in
    loop ();
    let s = Buffer.contents buf in
    if !is_float then add (TokFloat (float_of_string s))
    else add (TokNumber (int_of_string s))

  and read_island_rest () =
    let buf = Buffer.create 32 in
    let rec loop () =
      match peek () with
      | None -> lex_error !lex_line "unterminated island literal"
      | Some '>' -> advance (); add (TokIsland (Buffer.contents buf))
      | Some c -> Buffer.add_char buf c; advance (); loop ()
    in
    loop ()

  and read_keyword () =
    assert (peek () = Some ':'); advance ();
    let buf = Buffer.create 8 in
    let rec loop () =
      match peek () with
      | Some c when is_symbol_char c -> Buffer.add_char buf c; advance (); loop ()
      | _ -> Buffer.contents buf
    in
    let name = loop () in
    if name = "" then add TokColon else add (TokKeyword name)

  and read_symbol () =
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | Some c when is_symbol_char c -> Buffer.add_char buf c; advance (); loop ()
      | _ -> Buffer.contents buf
    in
    let name = loop () in
    if name = "" then lex_error !lex_line "empty symbol";
    add (TokSymbol name)

  and is_symbol_char c =
    match c with
    | ' ' | '\t' | '\n' | '\r' | ',' -> false
    | '(' | ')' | '[' | ']' | '{' | '}' -> false
    | '<' -> false
    | '\'' | '`' | '"' | ';' | '#' | '~' -> false
    | _ -> true
  in

  next_delim ();
  List.rev !tokens


(* ---- Parser ---- *)

type parse_state = {
  tokens : (token * int) array;
  mutable pos : int;
}

let make_ps tokens = { tokens = Array.of_list tokens; pos = 0 }
let peek ps =
  if ps.pos < Array.length ps.tokens then fst ps.tokens.(ps.pos) else TokEOF
let peek_line ps =
  if ps.pos < Array.length ps.tokens then snd ps.tokens.(ps.pos) else 1
let advance ps = ps.pos <- ps.pos + 1
let next ps = let t = peek ps in advance ps; t

(* Check if a token is a specific symbol *)
let is_symbol ps name =
  match peek ps with TokSymbol n when n = name -> true | _ -> false

let parse_error ps msg =
  let file = !current_file in
  let line = peek_line ps in
  failwith (Printf.sprintf "%s at %s:%d" msg file line)

(* Collect items until the [closing] delimiter (consumed); [what] names the
   form in the unterminated-at-EOF error. One loop for every bracketed form. *)
let parse_until ps ~(closing : token) ~(what : string) (item : parse_state -> 'a) : 'a list =
  let rec loop acc =
    match peek ps with
    | t when t = closing -> advance ps; List.rev acc
    | TokEOF -> parse_error ps ("unterminated " ^ what)
    | _ -> loop (item ps :: acc)
  in
  loop []

(* Parse a symbol from a token or error *)
let expect_symbol ps =
  match next ps with
  | TokSymbol s -> s
  | TokKeyword k -> k
  | t -> parse_error ps ("expected symbol, got " ^ string_of_token t)

(* Blocks (do bodies, multi-expression fn/def/let bodies, modules) give every
   def whole-block letrec* scope, so one name defined twice in a block is
   incoherent. Function defs keep their pre-existing shadowing latitude; any
   collision involving a VALUE def is rejected at read time. *)
let check_block_defs ps (exprs : expr list) : expr list =
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
             parse_error ps ("duplicate definition in block: " ^ n)
         | Some _ -> ()
         | None -> Hashtbl.add seen n is_val))
    exprs;
  exprs

(* Assemble a body from the expressions of a block, validating its defs. *)
let block_body ps (exprs : expr list) : expr =
  match check_block_defs ps exprs with
  | [b] -> b
  | bs -> EDo bs

(* Parse an expression *)
let rec parse_expr ps : expr =
  match peek ps with
  | TokEOF -> parse_error ps "unexpected end of input"
  | TokRParen | TokRBracket | TokRBrace ->
      parse_error ps "unexpected closing delimiter"
  | TokDot -> parse_error ps "unexpected dot"
  | TokColon -> parse_error ps "unexpected colon"
  | TokQuote ->
      advance ps; EQuote (parse_expr ps)
  | TokQuasiquote ->
      advance ps; EApply (ESymbol "quasiquote", [parse_qq_expr ps])
  | TokUnquote ->
      advance ps; EApply (ESymbol "unquote", [parse_expr ps])
  | TokUnquoteSplicing ->
      advance ps; EApply (ESymbol "unquote-splicing", [parse_expr ps])
  | TokString s -> advance ps; ELiteral (VString s)
  | TokNumber n -> advance ps; ELiteral (VInt n)
  | TokFloat f -> advance ps; ELiteral (VFloat f)
  | TokKeyword k -> advance ps; ELiteral (VKeyword k)
  | TokSymbol "nil" -> advance ps; ELiteral VNil
  | TokSymbol "true" -> advance ps; ELiteral (VBool true)
  | TokSymbol "false" -> advance ps; ELiteral (VBool false)
  | TokSymbol s -> advance ps; ESymbol s
  | TokIsland s -> advance ps; ELiteral (VString s)
  | TokLParen -> parse_list ps
  | TokLBracket -> parse_vector ps
  | TokLBrace -> parse_map ps
  | TokSharpLBrace -> parse_set ps

(* Parse a list: (expr ...)  or  (special-form ...) *)
and parse_list ps =
  advance ps;  (* consume ( *)
  match peek ps with
  | TokRParen -> advance ps; ELiteral VNil  (* empty list *)
  | TokSymbol s ->
      (* Check for special forms by looking at the car symbol *)
      parse_special_form ps s
  | _ ->
      (* Not a special form: (fn-expr arg ...) *)
      let fn_expr = parse_expr ps in
      let args = parse_rest ps in
      EApply (fn_expr, args)

(* Parse special forms where the car is a known symbol *)
and parse_special_form ps car_sym =
  advance ps;  (* consume the car symbol *)
  match car_sym with
  | "def" -> parse_def ps
  | "fn" -> parse_fn ps
  | "if" -> parse_if ps
  | "let" -> parse_let ps
  | "let*" -> parse_let_star ps
  | "and" -> parse_and ps
  | "or" -> parse_or ps
  | "quote" -> parse_quote ps
  | "force" -> parse_force ps
  | "delay" -> parse_delay ps
  | "node" -> parse_node ps
  | "defnode" -> parse_defnode ps
  | "do" -> parse_do ps
  | "effect" -> parse_effect ps
  | "perform" -> parse_perform ps
  | "with-handler" -> parse_with_handler ps
  | "module" -> parse_module ps
  | "import" -> parse_import ps
  | "load" -> parse_load ps
  | "load-module" -> parse_load_module ps
  | "island" -> parse_island ps
  | "with-config" -> parse_with_config ps
  | "config" -> parse_config ps
  | "assert" -> parse_assert ps
  | _ ->
      (* Regular function call: (fn-name arg ...) *)
      let args = parse_rest ps in
      EApply (ESymbol car_sym, args)

(* Parse the rest of a list (all expressions until closing paren) *)
and parse_rest ps =
  parse_until ps ~closing:TokRParen ~what:"list" parse_expr

(* Parse a vector of expressions [e1 e2 ...] *)
and parse_vector_exprs ps =
  begin match next ps with
    | TokLBracket -> ()
    | t -> parse_error ps ("expected '[', got " ^ string_of_token t)
  end;
  parse_until ps ~closing:TokRBracket ~what:"vector" parse_expr

(* Parse a vector parameter list [name1 : type1 name2 : type2 ...]
   Returns (name, type-annotation option) pairs; annotations are CHECKED —
   the def/fn assembler desugars each into a located type check ahead of the
   body (LAW 32; they were parsed-then-discarded before). *)
and parse_vector_param_list ps =
  begin match next ps with
    | TokLBracket -> ()
    | t -> parse_error ps ("expected '[', got " ^ string_of_token t)
  end;
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> advance ps
    | TokEOF -> parse_error ps "unterminated parameter vector"
    | TokSymbol s ->
        advance ps;
        (match peek ps with
         | TokColon ->
             advance ps;
             let ty = parse_expr ps in
             result := (s, Some ty) :: !result;
             loop ()
         | _ ->
             result := (s, None) :: !result;
             loop ())
    | TokColon ->
        advance ps;
        ignore (parse_expr ps);
        loop ()
    | _ -> parse_error ps "fn vector params must be symbols"
  in
  loop ();
  List.rev !result

(* Assemble a function's parameter names and body: each annotated parameter
   desugars into a located type check run ahead of the body — both backends
   compile/evaluate the shared desugared AST, so the checks are enforced
   identically (LAW 32). An optional return annotation wraps the body. *)
and assemble_fn_body locate (params : (string * expr option) list)
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

(* (def name value)  or  (def (name params...) [: type] body...) *)
and parse_def ps =
  let line = peek_line ps in
  let locate e = ELocated ((!current_file, line), e) in
  match peek ps with
  | TokLParen ->
      (* (def (name params...) [: type] body...) *)
      advance ps;  (* consume ( *)
      let name = expect_symbol ps in
      let params = parse_param_list ps in  (* consumes ) after params *)
      let ret_ty =
        match peek ps with
        | TokColon -> advance ps; Some (parse_expr ps)
        | _ -> None in
      let body = block_body ps (parse_rest ps) in
      let param_names, body' = assemble_fn_body locate params ret_ty body in
      EDef (name, param_names, body')
  | TokSymbol name ->
      (* (def name value) — a VALUE binding (evaluated at definition time),
         not a nullary closure: the ROADMAP §1 footgun fix. *)
      advance ps;
      let value = parse_expr ps in
      ignore (parse_rest ps);  (* consume ) and any trailing *)
      EDefValue (name, locate value)
  | _ -> parse_error ps "malformed def"

(* (fn [params...] [: type] body...) or (fn (params...) [: type] body...) *)
and parse_fn ps =
  let line = peek_line ps in
  let locate e = ELocated ((!current_file, line), e) in
  let params =
    match peek ps with
    | TokLBracket -> parse_vector_param_list ps
    | TokLParen ->
        advance ps;
        parse_param_list ps
    | _ -> parse_error ps "fn requires parameter list"
  in
  let ret_ty =
    match peek ps with
    | TokColon -> advance ps; Some (parse_expr ps)
    | _ -> None in
  let body = block_body ps (parse_rest ps) in
  let param_names, body' = assemble_fn_body locate params ret_ty body in
  EFn (param_names, body')

(* Parse a parameter list: name1 [: type1] name2 [: type2] ... ) — consumes
   the closing paren. Returns (name, type-annotation option) pairs; the
   annotations are CHECKED via desugared body checks (LAW 32). *)
and parse_param_list ps =
  let rec loop () =
    match peek ps with
    | TokRParen -> advance ps; []
    | TokColon ->
        (* Per-parameter type annotation before the parameter name is invalid,
           but consume it and the closing paren gracefully. *)
        advance ps;
        ignore (parse_expr ps);
        expect_rparen ps;
        []
    | TokSymbol s ->
        advance ps;
        (match peek ps with
         | TokColon ->
             advance ps;
             let ty = parse_expr ps in
             (s, Some ty) :: loop ()
         | _ -> (s, None) :: loop ())
    | _ -> parse_error ps "expected parameter symbol"
  and expect_rparen ps =
    match next ps with
    | TokRParen -> ()
    | _ -> parse_error ps "expected ) after parameter type annotation"
  in
  loop ()

(* (if cond then else) *)
and parse_if ps =
  let cond = parse_expr ps in
  let then_e = parse_expr ps in
  let else_e = match peek ps with
    | TokRParen -> ELiteral VNil
    | _ -> parse_expr ps
  in
  ignore (parse_rest ps);  (* consume ) and any trailing *)
  EIf (cond, then_e, else_e)

(* Parse a binding vector [name [: type] value ...] for let.
   If a type annotation is present the binding value is wrapped in ETyped. *)
and parse_binding_vector ps =
  begin match next ps with
    | TokLBracket -> ()
    | t -> parse_error ps ("expected '[', got " ^ string_of_token t)
  end;
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> advance ps
    | TokEOF -> parse_error ps "unterminated binding vector"
    | TokSymbol s ->
        advance ps;
        let ty = match peek ps with
          | TokColon -> advance ps; Some (parse_expr ps)
          | _ -> None in
        let value = parse_expr ps in
        let value' = match ty with
          | Some t -> ETyped (value, t)
          | None -> value in
        result := (s, value') :: !result;
        loop ()
    | _ -> parse_error ps "let binding name must be symbol"
  in
  loop ();
  List.rev !result

(* (let [name [: type] value ...] body...) *)
and parse_let ps =
  let bindings =
    match peek ps with
    | TokLBracket -> parse_binding_vector ps
    | TokLParen ->
        advance ps;
        let rec loop pairs =
          match peek ps with
          | TokRParen -> advance ps; List.rev pairs
          | _ ->
              let name = match parse_expr ps with
                | ESymbol s -> s | _ -> parse_error ps "let binding name must be symbol"
              in
              let ty = match peek ps with
                | TokColon -> advance ps; Some (parse_expr ps)
                | _ -> None in
              let value = parse_expr ps in
              let value' = match ty with
                | Some t -> ETyped (value, t)
                | None -> value in
              loop ((name, value') :: pairs)
        in
        loop []
    | _ -> parse_error ps "let requires binding vector"
  in
  let body = block_body ps (parse_rest ps) in
  ELet (bindings, body)

(* (quote expr) *)
and parse_quote ps =
  let e = parse_expr ps in
  ignore (parse_rest ps);
  EQuote e

(* (and exprs...) — short-circuiting AND *)
and parse_and ps =
  let exprs = parse_rest ps in
  let rec desugar = function
    | [] -> ELiteral (VBool true)
    | [e] -> e
    | e :: rest -> EIf (e, desugar rest, ELiteral (VBool false))
  in
  desugar exprs

(* (or exprs...) — short-circuiting OR *)
and parse_or ps =
  let exprs = parse_rest ps in
  let rec desugar = function
    | [] -> ELiteral (VBool false)
    | [e] -> e
    | e :: rest -> EIf (e, ELiteral (VBool true), desugar rest)
  in
  desugar exprs

(* (force expr) *)
and parse_force ps =
  let e = parse_expr ps in
  ignore (parse_rest ps);
  EForce e

(* (delay expr) *)
and parse_delay ps =
  let e = parse_expr ps in
  ignore (parse_rest ps);
  EDelay e

(* (node expr) *)
and parse_node ps =
  let e = parse_expr ps in
  ignore (parse_rest ps);
  ENode e

(* (defnode name value) or (defnode (name params...) [: type] body...) *)
and parse_defnode ps =
  let line = peek_line ps in
  let locate e = ELocated ((!current_file, line), e) in
  match peek ps with
  | TokLParen ->
      (* (defnode (name params...) [: type] body...) *)
      advance ps;  (* consume ( *)
      let name = expect_symbol ps in
      let params = parse_param_list ps in  (* consumes ) after params *)
      let ret_ty =
        match peek ps with
        | TokColon -> advance ps; Some (parse_expr ps)
        | _ -> None in
      let body = block_body ps (parse_rest ps) in
      let param_names, body' = assemble_fn_body locate params ret_ty body in
      EDefNode (name, param_names, body')
  | TokSymbol name ->
      (* (defnode name e) — a value binding of the node thunk of e, i.e.
         (def name (node e)): forcing `name` runs/caches the node. *)
      advance ps;
      let value = parse_expr ps in
      ignore (parse_rest ps);  (* consume ) and any trailing *)
      EDefValue (name, locate (ENode value))
  | _ -> parse_error ps "malformed defnode"

(* (assert cond [msg]) — a located runtime check: a false/nil condition
   raises `assertion failed: <form> at file:line` (or the custom message,
   location appended). Desugars to if+error so both backends enforce the
   shared AST identically. *)
and parse_assert ps =
  let line = peek_line ps in
  let loc_suffix = Printf.sprintf " at %s:%d" !current_file line in
  let cond = parse_expr ps in
  let msg_opt = match peek ps with
    | TokRParen -> None
    | _ -> Some (parse_expr ps) in
  ignore (parse_rest ps);
  let msg_expr = match msg_opt with
    | None ->
        ELiteral (VString ("assertion failed: "
                           ^ string_of_value (quote_to_value cond)
                           ^ loc_suffix))
    | Some m ->
        EApply (ESymbol "string-append", [m; ELiteral (VString loc_suffix)]) in
  EIf (cond, ELiteral VNil, EApply (ESymbol "error", [msg_expr]))

(* (do exprs...) *)
and parse_do ps =
  let exprs = parse_rest ps in
  EDo (check_block_defs ps exprs)

(* (let* [name expr name2 expr2 ...] body...) — sequential let *)
and parse_let_star ps =
  let bindings =
    match peek ps with
    | TokLBracket -> parse_vector_exprs ps
    | _ -> parse_error ps "let* requires binding vector"
  in
  let rec pair_up = function
    | [] -> []
    | [e] -> parse_error ps "let* bindings must be pairs"
    | (ESymbol s) :: v :: rest -> (s, v) :: pair_up rest
    | _ :: _ -> parse_error ps "let* binding name must be symbol"
  in
  let bindings = pair_up bindings in
  let body = block_body ps (parse_rest ps) in
  ELetStar (bindings, body)

(* (effect :capabilities [cap-exprs...] body...) or (effect body...) *)
and parse_effect ps =
  let caps_expr =
    match peek ps with
    | TokKeyword "capabilities" ->
        advance ps;
        (match peek ps with
         | TokLBracket ->
             let exprs = parse_vector_exprs ps in
             EApply (ESymbol "list", exprs)  (* wrap as list *)
         | _ -> parse_expr ps)
    | _ -> ELiteral VNil  (* no capabilities *)
  in
  let body = block_body ps (parse_rest ps) in
  EEffect (caps_expr, body)

(* (perform effect-name args...) *)
and parse_perform ps =
  let name = expect_symbol ps in
  let args = parse_rest ps in
  EPerform (name, args)

(* (with-handler [effect-name handler-fn ...] body...) *)
and parse_with_handler ps =
  let handlers =
    match peek ps with
    | TokLBracket -> parse_vector_exprs ps
    | _ -> parse_error ps "with-handler requires handler vector"
  in
  let rec pair_up exprs =
    match exprs with
    | [] -> []
    | [e] -> parse_error ps "handler specs must be pairs"
    | (ESymbol s) :: h :: rest -> (s, h) :: pair_up rest
    | (ELiteral (VKeyword k)) :: h :: rest -> (k, h) :: pair_up rest
    | _ :: _ -> parse_error ps "handler name must be symbol or keyword"
  in
  let handlers = pair_up handlers in
  let body = block_body ps (parse_rest ps) in
  EWithHandler (handlers, body)

(* (module body-exprs...) — creates a thunk that evaluates to an environment *)
and parse_module ps =
  let body = parse_rest ps in
  EModule (check_block_defs ps body)

(* (import mod-expr) — force a module thunk and merge its bindings *)
and parse_import ps =
  let mod_expr = parse_expr ps in
  ignore (parse_rest ps);  (* consume ) and any trailing *)
  EImport mod_expr

(* (load "file.pp") — evaluate a file in the current environment *)
and parse_load ps =
  match peek ps with
  | TokString path ->
      advance ps;
      ignore (parse_rest ps);
      ELoad path
  | _ -> parse_error ps "load expects a string path"

(* (load-module "file.pp") — evaluate a file as a module, returning an env map *)
and parse_load_module ps =
  match peek ps with
  | TokString path ->
      advance ps;
      ignore (parse_rest ps);
      ELoadModule path
  | _ -> parse_error ps "load-module expects a string path"

(* (island <uri>[#ref] ["64-hex-pin"]) — content-addressed remote module (D2).
   The URI may be written bare (file:./lib), as an island literal
   (<github:owner/repo#main> — '#' is not a symbol char), or as a string.
   The optional pin is the canonical tree hash, usually written as a string
   (a bare 64-hex symbol starting with a digit would lex as a number). *)
and parse_island ps =
  let uri = match next ps with
    | TokIsland s -> s
    | TokString s -> s
    | TokSymbol s -> s
    | t -> parse_error ps ("island expects <uri>, got " ^ string_of_token t)
  in
  let pin = match peek ps with
    | TokString s -> advance ps; Some s
    | TokSymbol s -> advance ps; Some s
    | _ -> None
  in
  ignore (parse_rest ps);
  EIsland (uri, pin)
(* (with-config {key val ...} body...) — ambient configuration block *)
and parse_with_config ps =
  let map_expr = parse_expr ps in
  let body = block_body ps (parse_rest ps) in
  EWithConfig (map_expr, body)

(* (config key [default]) — read ambient config key *)
and parse_config ps =
  let key_expr = parse_expr ps in
  let default_opt = match peek ps with
    | TokRParen -> None
    | _ -> Some (parse_expr ps) in
  advance ps;  (* consume ) *)
  EConfig (key_expr, default_opt)

(* (vector e1 e2 ...) — already inside a [ ... ] parsed as EApply *)
and parse_vector ps =
  advance ps;  (* consume [ *)
  EApply (ESymbol "vector", parse_until ps ~closing:TokRBracket ~what:"vector" parse_expr)

(* {key val ...} — map literal *)
and parse_map ps =
  advance ps;  (* consume { *)
  let pairs = parse_until ps ~closing:TokRBrace ~what:"map"
    (fun ps -> let k = parse_expr ps in let v = parse_expr ps in (k, v)) in
  EApply (ESymbol "hash-map", List.concat_map (fun (k, v) -> [k; v]) pairs)

(* #{expr ...} — set literal *)
and parse_set ps =
  advance ps;  (* consume #{ *)
  EApply (ESymbol "hash-set", parse_until ps ~closing:TokRBrace ~what:"set" parse_expr)

(* ---- Quasiquote mode parsers ----
   In quasiquote mode, everything is treated as quoted data.  , and ,@
   escape back to normal evaluation.  The emitted AST builds a value
   structure (with unquote markers) that the quasiquote function walks. *)

and parse_qq_expr ps =
  match peek ps with
  | TokEOF -> parse_error ps "unexpected end of input in quasiquote"
  | TokRParen | TokRBracket | TokRBrace ->
      parse_error ps "unexpected closing delimiter in quasiquote"
  | TokUnquote ->
      (* ,form  →  (list 'unquote form) — form evaluated NORMALLY *)
      advance ps;
      EApply (ESymbol "list", [EQuote (ESymbol "unquote"); parse_expr ps])
  | TokUnquoteSplicing ->
      (* ,@form  →  (list 'unquote-splicing form) *)
      advance ps;
      EApply (ESymbol "list", [EQuote (ESymbol "unquote-splicing"); parse_expr ps])
  | TokQuote ->
      (* 'form inside quasiquote: quote the qq-parsed form *)
      advance ps;
      EQuote (parse_qq_expr ps)
  | TokQuasiquote ->
      (* nested quasiquote: (quasiquote <qq-parsed>) *)
      advance ps;
      EApply (ESymbol "quasiquote", [parse_qq_expr ps])
  | TokLParen ->
      parse_qq_list ps
  | TokLBracket ->
      parse_qq_vector ps
  | TokLBrace ->
      (* {k v ...} → (hash-map (qq k) (qq v) ...) *)
      advance ps;
      let pairs = parse_until ps ~closing:TokRBrace ~what:"map in quasiquote"
        (fun ps -> let k = parse_qq_expr ps in let v = parse_qq_expr ps in (k, v)) in
      EApply (ESymbol "hash-map", List.concat_map (fun (k, v) -> [k; v]) pairs)
  | TokSharpLBrace ->
      (* #{e ...} → (hash-set (qq e) ...) *)
      advance ps;
      EApply (ESymbol "hash-set",
              parse_until ps ~closing:TokRBrace ~what:"set in quasiquote" parse_qq_expr)
  | _ ->
      (* Any atom: wrap in quote so it evaluates to itself *)
      EQuote (parse_expr ps)

(* Parse a list in quasiquote mode: (a b c) → (cons (qq a) (cons (qq b) (cons (qq c) '()))) *)
and parse_qq_list ps =
  advance ps;  (* consume ( *)
  let elems = parse_until ps ~closing:TokRParen ~what:"list in quasiquote" parse_qq_expr in
  List.fold_right (fun e acc ->
    EApply (ESymbol "cons", [e; acc])
  ) elems (EQuote (ELiteral VNil))

(* Parse a vector in quasiquote mode: [a b c] → (vector (qq a) (qq b) (qq c)) *)
and parse_qq_vector ps =
  advance ps;  (* consume [ *)
  EApply (ESymbol "vector",
          parse_until ps ~closing:TokRBracket ~what:"vector in quasiquote" parse_qq_expr)


(* ---- Public API ---- *)

let read_string ?(source : string = "<?>") (input : string) : expr list =
  current_file := source;
  lex_line := 1;
  let tokens = lex input in
  let ps = make_ps tokens in
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokEOF -> ()
    | _ ->
        let line = peek_line ps in
        let e = parse_expr ps in
        result := ELocated ((source, line), e) :: !result;
        loop ()
  in
  loop ();
  List.rev !result

let read_one ?(source : string = "<?>") (input : string) : expr =
  match read_string ~source input with
  | [e] -> e
  | [] -> failwith (Printf.sprintf "empty input at %s:1" source)
  | _ -> failwith (Printf.sprintf "multiple expressions at %s:1" source)
