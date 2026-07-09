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

(* Lex a string into a list of tokens *)
let lex (input : string) : token list =
  let len = String.length input in
  let pos = ref 0 in
  let tokens = ref [] in

  let add t = tokens := t :: !tokens in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let advance () = let c = input.[!pos] in pos := !pos + 1; c in

  let rec next_delim () =
    match peek () with
    | None -> ()
    | Some c ->
      if c = ' ' || c = '\t' || c = '\n' || c = '\r' || c = ',' then
        (ignore (advance ()); next_delim ())
      else if c = ';' then
        (ignore (advance ()); skip_comment ())
      else
        (token (); next_delim ())

  and skip_comment () =
    match peek () with
    | Some '\n' | Some '\r' | None -> ignore (advance ()); next_delim ()
    | Some _ -> ignore (advance ()); skip_comment ()

  and token () =
    match peek () with
    | None -> add TokEOF
    | Some '(' -> add TokLParen; ignore (advance ())
    | Some ')' -> add TokRParen; ignore (advance ())
    | Some '[' -> add TokLBracket; ignore (advance ())
    | Some ']' -> add TokRBracket; ignore (advance ())
    | Some '{' -> add TokLBrace; ignore (advance ())
    | Some '}' -> add TokRBrace; ignore (advance ())
    | Some '<' ->
        ignore (advance ());
        (match peek () with
         | Some '=' -> ignore (advance ()); add (TokSymbol "<=")
         | Some c when (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ->
             read_island_rest ()
         | _ -> add (TokSymbol "<"))
    | Some '\'' -> add TokQuote; ignore (advance ())
    | Some '`' -> add TokQuasiquote; ignore (advance ())
    | Some ',' ->
        ignore (advance ());
        (match peek () with Some '@' -> ignore (advance ()); add TokUnquoteSplicing | _ -> add TokUnquote)
    | Some '#' ->
        ignore (advance ());
        (match peek () with
         | Some '{' -> ignore (advance ()); add TokSharpLBrace
         | _ -> failwith ("unexpected character after #"))
    | Some '"' -> read_string ()
    | Some '-' ->
        (match peek () with Some c when c >= '0' && c <= '9' -> read_number ()
                            | _ -> read_symbol ())
    | Some c when c >= '0' && c <= '9' -> read_number ()
    | Some ':' -> read_keyword ()
    | Some _ -> read_symbol ()

  and read_string () =
    assert (advance () = '"');
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | None -> failwith "unterminated string"
      | Some '"' -> advance (); add (TokString (Buffer.contents buf))
      | Some '\\' ->
          advance ();
          (match peek () with
           | Some 'n' -> advance (); Buffer.add_char buf '\n'; loop ()
           | Some 't' -> advance (); Buffer.add_char buf '\t'; loop ()
           | Some '\\' -> advance (); Buffer.add_char buf '\\'; loop ()
           | Some '"' -> advance (); Buffer.add_char buf '"'; loop ()
           | Some c -> advance (); Buffer.add_char buf c; loop ()
           | None -> failwith "unterminated escape")
      | Some c -> advance (); Buffer.add_char buf c; loop ()
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
      | None -> failwith "unterminated island literal"
      | Some '>' -> advance (); add (TokIsland (Buffer.contents buf))
      | Some c -> Buffer.add_char buf c; advance (); loop ()
    in
    loop ()

  and read_keyword () =
    assert (advance () = ':');
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
    if name = "" then failwith "empty symbol";
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
  mutable tokens : token list;
  mutable pos : int;
}

let make_ps tokens = { tokens; pos = 0 }
let peek ps = if ps.pos < List.length ps.tokens then List.nth ps.tokens ps.pos else TokEOF
let advance ps = let t = peek ps in ps.pos <- ps.pos + 1; t

(* Check if a token is a specific symbol *)
let is_symbol ps name =
  match peek ps with TokSymbol n when n = name -> true | _ -> false

(* Parse a symbol from a token or error *)
let expect_symbol ps =
  match advance ps with
  | TokSymbol s -> s
  | TokKeyword k -> k
  | t -> failwith ("expected symbol, got " ^ string_of_token t)

(* Parse an expression *)
let rec parse_expr ps : expr =
  match peek ps with
  | TokEOF -> failwith "unexpected end of input"
  | TokRParen | TokRBracket | TokRBrace ->
      failwith ("unexpected closing delimiter")
  | TokDot -> failwith "unexpected dot"
  | TokColon -> failwith "unexpected colon"
  | TokQuote ->
      advance ps; EQuote (parse_expr ps)
  | TokQuasiquote ->
      advance ps; EApply (ESymbol "quasiquote", [parse_expr ps])
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
  ignore (advance ps);  (* consume ( *)
  match peek ps with
  | TokRParen -> ignore (advance ps); ELiteral VNil  (* empty list *)
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
  ignore (advance ps);  (* consume the car symbol *)
  match car_sym with
  | "def" -> parse_def ps
  | "def-fexpr" -> parse_def_fexpr ps
  | "fn" -> parse_fn ps
  | "if" -> parse_if ps
  | "let" -> parse_let ps
  | "let*" -> parse_let_star ps
  | "and" -> parse_and ps
  | "or" -> parse_or ps
  | "quote" -> parse_quote ps
  | "force" -> parse_force ps
  | "delay" -> parse_delay ps
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
  | _ ->
      (* Regular function call: (fn-name arg ...) *)
      let args = parse_rest ps in
      EApply (ESymbol car_sym, args)

(* Parse the rest of a list (all expressions until closing paren) *)
and parse_rest ps =
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRParen -> ignore (advance ps)
    | TokEOF -> failwith "unterminated list"
    | _ ->
        let e = parse_expr ps in
        result := e :: !result;
        loop ()
  in
  loop ();
  List.rev !result

(* Parse a vector of expressions [e1 e2 ...] *)
and parse_vector_exprs ps =
  begin match advance ps with
    | TokLBracket -> ()
    | t -> failwith ("expected '[', got " ^ string_of_token t)
  end;
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> ignore (advance ps)
    | TokEOF -> failwith "unterminated vector"
    | _ ->
        let e = parse_expr ps in
        result := e :: !result;
        loop ()
  in
  loop ();
  List.rev !result

(* Parse a vector parameter list [name1 : type1 name2 : type2 ...]
   Type annotations are parsed and ignored for v1. *)
and parse_vector_param_list ps =
  begin match advance ps with
    | TokLBracket -> ()
    | t -> failwith ("expected '[', got " ^ string_of_token t)
  end;
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> ignore (advance ps)
    | TokEOF -> failwith "unterminated parameter vector"
    | TokSymbol s ->
        advance ps;
        result := s :: !result;
        (match peek ps with
         | TokColon -> ignore (advance ps); ignore (parse_expr ps); loop ()
         | _ -> loop ())
    | TokColon ->
        ignore (advance ps);
        ignore (parse_expr ps);
        loop ()
    | _ -> failwith "fn vector params must be symbols"
  in
  loop ();
  List.rev !result

(* (def name value)  or  (def (name params...) [: type] body...) *)
and parse_def ps =
  match peek ps with
  | TokLParen ->
      (* (def (name params...) [: type] body...) *)
      ignore (advance ps);  (* consume ( *)
      let name = expect_symbol ps in
      let params = parse_param_list ps in  (* consumes ) after params *)
      let ret_ty =
        match peek ps with
        | TokColon -> ignore (advance ps); Some (parse_expr ps)
        | _ -> None in
      let body = match parse_rest ps with
        | [b] -> b | bs -> EDo bs in
      let body' = match ret_ty with
        | Some ty -> ETyped (body, ty)
        | None -> body in
      EDef (name, params, body')
  | TokSymbol name ->
      ignore (advance ps);
      let value = parse_expr ps in
      ignore (parse_rest ps);  (* consume ) and any trailing *)
      EDef (name, [], value)  (* variable definition *)
  | _ -> failwith "malformed def"

(* (fn [params...] [: type] body...) or (fn (params...) [: type] body...) *)
and parse_fn ps =
  let params =
    match peek ps with
    | TokLBracket -> parse_vector_param_list ps
    | TokLParen ->
        ignore (advance ps);
        parse_param_list ps
    | _ -> failwith "fn requires parameter list"
  in
  let ret_ty =
    match peek ps with
    | TokColon -> ignore (advance ps); Some (parse_expr ps)
    | _ -> None in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
  let body' = match ret_ty with
    | Some ty -> ETyped (body, ty)
    | None -> body in
  EFn (params, body')

(* Parse a parameter list: name1 [: type1] name2 [: type2] ... ) — consumes the closing paren.
   Type annotations are parsed and ignored for v1; only parameter names are returned. *)
and parse_param_list ps =
  let rec loop () =
    match peek ps with
    | TokRParen -> advance ps; []
    | TokColon ->
        (* Per-parameter type annotation before the parameter name is invalid,
           but consume it and the closing paren gracefully. *)
        ignore (advance ps);
        ignore (parse_expr ps);
        expect_rparen ps;
        []
    | TokSymbol s ->
        advance ps;
        (match peek ps with
         | TokColon ->
             ignore (advance ps);
             ignore (parse_expr ps);  (* consume per-parameter type annotation *)
             s :: loop ()
         | _ -> s :: loop ())
    | _ -> failwith "expected parameter symbol"
  and expect_rparen ps =
    match advance ps with
    | TokRParen -> ()
    | _ -> failwith "expected ) after parameter type annotation"
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
  begin match advance ps with
    | TokLBracket -> ()
    | t -> failwith ("expected '[', got " ^ string_of_token t)
  end;
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> ignore (advance ps)
    | TokEOF -> failwith "unterminated binding vector"
    | TokSymbol s ->
        advance ps;
        let ty = match peek ps with
          | TokColon -> ignore (advance ps); Some (parse_expr ps)
          | _ -> None in
        let value = parse_expr ps in
        let value' = match ty with
          | Some t -> ETyped (value, t)
          | None -> value in
        result := (s, value') :: !result;
        loop ()
    | _ -> failwith "let binding name must be symbol"
  in
  loop ();
  List.rev !result

(* (let [name [: type] value ...] body...) *)
and parse_let ps =
  let bindings =
    match peek ps with
    | TokLBracket -> parse_binding_vector ps
    | TokLParen ->
        ignore (advance ps);
        let rec loop pairs =
          match peek ps with
          | TokRParen -> ignore (advance ps); List.rev pairs
          | _ ->
              let name = match parse_expr ps with
                | ESymbol s -> s | _ -> failwith "let binding name must be symbol"
              in
              let ty = match peek ps with
                | TokColon -> ignore (advance ps); Some (parse_expr ps)
                | _ -> None in
              let value = parse_expr ps in
              let value' = match ty with
                | Some t -> ETyped (value, t)
                | None -> value in
              loop ((name, value') :: pairs)
        in
        loop []
    | _ -> failwith "let requires binding vector"
  in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
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

(* (do exprs...) *)
and parse_do ps =
  let exprs = parse_rest ps in
  EDo exprs

(* (def-fexpr name (params...) body...) *)
and parse_def_fexpr ps =
  match peek ps with
  | TokLParen ->
      ignore (advance ps);
      let name = expect_symbol ps in
      let params = parse_param_list ps in
      let body = match parse_rest ps with
        | [b] -> b | bs -> EDo bs in
      EDefFexpr (name, params, body)
  | TokSymbol name ->
      ignore (advance ps);
      let value = parse_expr ps in
      ignore (parse_rest ps);
      EDefFexpr (name, [], value)
  | _ -> failwith "malformed def-fexpr"

(* (let* [name expr name2 expr2 ...] body...) — sequential let *)
and parse_let_star ps =
  let bindings =
    match peek ps with
    | TokLBracket -> parse_vector_exprs ps
    | _ -> failwith "let* requires binding vector"
  in
  let rec pair_up = function
    | [] -> []
    | [e] -> failwith "let* bindings must be pairs"
    | (ESymbol s) :: v :: rest -> (s, v) :: pair_up rest
    | _ :: _ -> failwith "let* binding name must be symbol"
  in
  let bindings = pair_up bindings in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
  (* Desugar to nested let: (let* [x 1 y 2] body) → (let [x 1] (let [y 2] body)) *)
  let rec nest = function
    | [] -> body
    | [(name, expr)] -> ELet ([(name, expr)], body)
    | (name, expr) :: rest -> ELet ([(name, expr)], nest rest)
  in
  nest bindings

(* (effect :capabilities [cap-exprs...] body...) or (effect body...) *)
and parse_effect ps =
  let caps_expr =
    match peek ps with
    | TokKeyword "capabilities" ->
        ignore (advance ps);
        (match peek ps with
         | TokLBracket ->
             let exprs = parse_vector_exprs ps in
             EApply (ESymbol "list", exprs)  (* wrap as list *)
         | _ -> parse_expr ps)
    | _ -> ELiteral VNil  (* no capabilities *)
  in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
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
    | _ -> failwith "with-handler requires handler vector"
  in
  let rec pair_up exprs =
    match exprs with
    | [] -> []
    | [e] -> failwith "handler specs must be pairs"
    | (ESymbol s) :: h :: rest -> (s, h) :: pair_up rest
    | (ELiteral (VKeyword k)) :: h :: rest -> (k, h) :: pair_up rest
    | _ :: _ -> failwith "handler name must be symbol or keyword"
  in
  let handlers = pair_up handlers in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
  EWithHandler (handlers, body)

(* (module body-exprs...) — creates a thunk that evaluates to an environment *)
and parse_module ps =
  let body = parse_rest ps in
  EModule body

(* (import mod-expr) — force a module thunk and merge its bindings *)
and parse_import ps =
  let mod_expr = parse_expr ps in
  ignore (parse_rest ps);  (* consume ) and any trailing *)
  EImport mod_expr

(* (load "file.pp") — evaluate a file in the current environment *)
and parse_load ps =
  match peek ps with
  | TokString path ->
      ignore (advance ps);
      ignore (parse_rest ps);
      ELoad path
  | _ -> failwith "load expects a string path"

(* (load-module "file.pp") — evaluate a file as a module, returning an env map *)
and parse_load_module ps =
  match peek ps with
  | TokString path ->
      ignore (advance ps);
      ignore (parse_rest ps);
      ELoadModule path
  | _ -> failwith "load-module expects a string path"

(* Stubs for new special forms — parsed but not yet evaluated. *)
and parse_island ps =
  let uri = match advance ps with
    | TokIsland s -> s
    | TokString s -> s
    | TokSymbol s -> s
    | t -> failwith ("island expects <uri>, got " ^ string_of_token t)
  in
  let version = match peek ps with
    | TokString s -> ignore (advance ps); Some s
    | TokSymbol s -> ignore (advance ps); Some s
    | _ -> None
  in
  ignore (parse_rest ps);
  EIsland (uri, version)
(* (with-config {key val ...} body...) — ambient configuration block *)
and parse_with_config ps =
  let map_expr = parse_expr ps in
  let body = match parse_rest ps with
    | [b] -> b | bs -> EDo bs in
  EWithConfig (map_expr, body)

(* (config key [default]) — read ambient config key *)
and parse_config ps =
  let key_expr = parse_expr ps in
  let default_opt = match peek ps with
    | TokRParen -> None
    | _ -> Some (parse_expr ps) in
  ignore (advance ps);  (* consume ) *)
  EConfig (key_expr, default_opt)

(* (vector e1 e2 ...) — already inside a [ ... ] parsed as EApply *)
and parse_vector ps =
  ignore (advance ps);  (* consume [ *)
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBracket -> ignore (advance ps)
    | TokEOF -> failwith "unterminated vector"
    | _ ->
        let e = parse_expr ps in
        result := e :: !result;
        loop ()
  in
  loop ();
  EApply (ESymbol "vector", List.rev !result)

(* {key val ...} — map literal *)
and parse_map ps =
  ignore (advance ps);  (* consume { *)
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBrace -> ignore (advance ps)
    | TokEOF -> failwith "unterminated map"
    | _ ->
        let k = parse_expr ps in
        let v = parse_expr ps in
        result := (k, v) :: !result;
        loop ()
  in
  loop ();
  let args = List.concat_map (fun (k, v) -> [k; v]) (List.rev !result) in
  EApply (ESymbol "hash-map", args)

(* #{expr ...} — set literal *)
and parse_set ps =
  ignore (advance ps);  (* consume #{ *)
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokRBrace -> ignore (advance ps)
    | TokEOF -> failwith "unterminated set"
    | _ ->
        let e = parse_expr ps in
        result := e :: !result;
        loop ()
  in
  loop ();
  EApply (ESymbol "hash-set", List.rev !result)


(* ---- Public API ---- *)

let read_string (input : string) : expr list =
  let tokens = lex input in
  let ps = make_ps tokens in
  let result = ref [] in
  let rec loop () =
    match peek ps with
    | TokEOF -> ()
    | _ ->
        let e = parse_expr ps in
        result := e :: !result;
        loop ()
  in
  loop ();
  List.rev !result

let read_one (input : string) : expr =
  match read_string input with
  | [e] -> e
  | [] -> failwith "empty input"
  | _ -> failwith "multiple expressions"
