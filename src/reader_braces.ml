(* pp brace reader — the M7 surface syntax (SPEC Appendix B), parsing to the
   IDENTICAL `Types.expr` the s-expression reader produces for the equivalent
   program: same AST, same `ELocated` placement (§B.4), same shared desugars
   (src/desugar.ml), hence the same LAW-20 keys. The grammar implemented here
   is exactly the one Appendix B froze in S0 — the 7-level precedence table,
   the whitespace-sensitive infix rule (`a - b` subtracts, `a-b` is one
   identifier), `#` comments, `;`/newline statement separators with
   syntactic-incompleteness continuation, expression-position `{}` always a
   map, blocks only after the closed set of block-taking heads, and lowering
   rows L1–L61.

   Location placement mirrors reader.ml's sites exactly:
   - every top-level statement: ELocated ((source, line-of-first-token), form)
   - `def`/`fn`/`node f(..)`: the line of the token AFTER the head keyword
     locates the body / return annotation / per-parameter checks
     (Desugar.assemble_fn_body)
   - `let x = e` / `node x { .. }`: EDefValue (x, ELocated (loc, rhs))
   - `assert`: the location is baked into the generated message string, with
     the condition rendered in s-expression notation (Desugar.desugar_assert).

   Error messages carry `msg at file:line` in the sexpr reader's exact format
   (LAW 29). *)

open Types

(* ---- Tokens ---- *)

type btok =
  | TLParen | TRParen
  | TLBracket | TRBracket
  | TLBrace | TRBrace
  | TComma | TSemi | TNewline
  | TString of string
  | TInt of int
  | TFloat of float
  | TName of string          (* identifiers AND operator spellings (+ - |> ->) *)
  | TKeyword of string
  | TColon                   (* annotation separator *)
  | TCell of string * string (* file:"P" / env:"N" / tree:"R" *)
  | TEOF

let string_of_btok = function
  | TLParen -> "(" | TRParen -> ")"
  | TLBracket -> "[" | TRBracket -> "]"
  | TLBrace -> "{" | TRBrace -> "}"
  | TComma -> "," | TSemi -> ";" | TNewline -> "newline"
  | TString s -> Printf.sprintf "\"%s\"" (String.escaped s)
  | TInt n -> string_of_int n
  | TFloat f -> string_of_float f
  | TName s -> s
  | TKeyword k -> ":" ^ k
  | TColon -> ":"
  | TCell (h, s) -> Printf.sprintf "%s:\"%s\"" h (String.escaped s)
  | TEOF -> "<eof>"

(* [glued] = no whitespace/comment between this token's first character and
   the previous token's last character — the carrier of Appendix B's
   whitespace rule (infix operators require surrounding whitespace). *)
type tok = { t : btok; tline : int; glued : bool }

(* Name characters: the sexpr reader's symbol characters minus ':' (§B.1).
   '<' is not a name character (lexed specially, as in sexprs). *)
let is_name_char c =
  match c with
  | ' ' | '\t' | '\n' | '\r' | ',' -> false
  | '(' | ')' | '[' | ']' | '{' | '}' -> false
  | '<' -> false
  | '\'' | '`' | '"' | ';' | '#' | '~' -> false
  | ':' -> false
  | _ -> true

let is_digit c = c >= '0' && c <= '9'

(* ---- Lexer ---- *)

let lex ~(file : string) (input : string) : tok list =
  let len = String.length input in
  let pos = ref 0 in
  let line = ref 1 in
  let toks = ref [] in
  let last_end = ref (-1) in   (* char index just past the previous token *)
  let lex_error l msg = failwith (Printf.sprintf "%s at %s:%d" msg file l) in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let peek_at k = if !pos + k < len then Some input.[!pos + k] else None in
  let advance () = incr pos in
  let add_at start start_line t =
    toks := { t; tline = start_line; glued = (start = !last_end) } :: !toks;
    last_end := !pos
  in
  (* String body: same escapes as the sexpr reader (backslash n/t/backslash/
     quote; any other backslashed char is itself); literal newlines allowed. *)
  let read_string_body start_line =
    advance ();  (* opening quote *)
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | None -> lex_error start_line "unterminated string"
      | Some '"' -> advance (); Buffer.contents buf
      | Some '\\' ->
          advance ();
          (match peek () with
           | Some 'n' -> advance (); Buffer.add_char buf '\n'; loop ()
           | Some 't' -> advance (); Buffer.add_char buf '\t'; loop ()
           | Some '\\' -> advance (); Buffer.add_char buf '\\'; loop ()
           | Some '"' -> advance (); Buffer.add_char buf '"'; loop ()
           | Some c -> advance (); Buffer.add_char buf c; loop ()
           | None -> lex_error start_line "unterminated escape")
      | Some c ->
          if c = '\n' then incr line;
          advance ();
          Buffer.add_char buf c;
          loop ()
    in
    loop ()
  in
  (* Numbers: mirrors the sexpr reader's read_number exactly (same consumed
     character set, same int/float split on '.'). *)
  let read_number start start_line =
    let buf = Buffer.create 8 in
    let is_float = ref false in
    let rec loop () =
      match peek () with
      | Some '.' when not !is_float ->
          is_float := true; Buffer.add_char buf '.'; advance (); loop ()
      | Some c when is_digit c || c = '-' || c = 'e' || c = 'E' || c = '+' ->
          Buffer.add_char buf c; advance (); loop ()
      | _ -> ()
    in
    loop ();
    let s = Buffer.contents buf in
    if !is_float then add_at start start_line (TFloat (float_of_string s))
    else
      (match int_of_string_opt s with
       | Some n -> add_at start start_line (TInt n)
       | None -> lex_error start_line ("invalid number literal: " ^ s))
  in
  let read_name () =
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | Some c when is_name_char c -> Buffer.add_char buf c; advance (); loop ()
      | _ -> Buffer.contents buf
    in
    loop ()
  in
  let prev_tok () = match !toks with t :: _ -> Some t | [] -> None in
  let rec run () =
    let start = !pos in
    let start_line = !line in
    match peek () with
    | None -> add_at start start_line TEOF
    | Some (' ' | '\t' | '\r') -> advance (); run ()
    | Some '\n' -> advance (); add_at start start_line TNewline; incr line; run ()
    | Some '#' ->
        (* comment to end of line; the newline itself is the next token *)
        while (match peek () with Some c when c <> '\n' -> true | _ -> false)
        do advance () done;
        run ()
    | Some ';' -> advance (); add_at start start_line TSemi; run ()
    | Some ',' -> advance (); add_at start start_line TComma; run ()
    | Some '(' -> advance (); add_at start start_line TLParen; run ()
    | Some ')' -> advance (); add_at start start_line TRParen; run ()
    | Some '[' -> advance (); add_at start start_line TLBracket; run ()
    | Some ']' -> advance (); add_at start start_line TRBracket; run ()
    | Some '{' -> advance (); add_at start start_line TLBrace; run ()
    | Some '}' -> advance (); add_at start start_line TRBrace; run ()
    | Some '"' ->
        let s = read_string_body start_line in
        add_at start start_line (TString s); run ()
    | Some '<' ->
        advance ();
        (match peek () with
         | Some '=' -> advance (); add_at start start_line (TName "<=")
         | Some '-' -> advance (); add_at start start_line (TName "<-")
         | _ -> add_at start start_line (TName "<"));
        run ()
    | Some ':' ->
        (* Glued to a preceding name or ')': annotation colon — or, glued to
           a name AND immediately followed by a string, a cell literal
           (file:"P" / env:"N" / tree:"R"; exactly those heads, §B.1).
           At token start (not glued): ':'+namechar is a keyword. *)
        let glued_prev =
          start = !last_end
          && (match prev_tok () with
              | Some { t = (TName _ | TRParen); _ } -> true
              | _ -> false)
        in
        if glued_prev then begin
          advance ();
          match peek (), prev_tok () with
          | Some '"', Some { t = TName head; tline = hl; glued = hg } ->
              if not (List.mem head ["file"; "env"; "tree"]) then
                lex_error start_line
                  (Printf.sprintf
                     "unknown cell literal '%s:\"...\"' (only file:, env:, tree: exist)"
                     head);
              let s = read_string_body start_line in
              (* replace the head name token with the fused cell token *)
              toks := List.tl !toks;
              toks := { t = TCell (head, s); tline = hl; glued = hg } :: !toks;
              last_end := !pos
          | _ -> add_at start start_line TColon
        end else begin
          advance ();
          match peek () with
          | Some c when is_name_char c ->
              let name = read_name () in
              add_at start start_line (TKeyword name)
          | _ -> add_at start start_line TColon
        end;
        run ()
    | Some '-' ->
        let next = peek_at 1 in
        let after = peek_at 2 in
        (match next with
         | Some c when is_digit c -> read_number start start_line
         | Some '.' when (match after with Some d -> is_digit d | None -> false) ->
             read_number start start_line
         | _ ->
             let name = read_name () in
             add_at start start_line (TName name));
        run ()
    | Some c when is_digit c -> read_number start start_line; run ()
    | Some c when is_name_char c ->
        let name = read_name () in
        add_at start start_line (TName name);
        run ()
    | Some c ->
        lex_error start_line (Printf.sprintf "unexpected character '%c'" c)
  in
  run ();
  List.rev !toks

(* ---- Parser ---- *)

type ps = {
  toks : tok array;
  mutable pos : int;
  file : string;
}

let eof_tok = { t = TEOF; tline = 1; glued = false }

let cur ps =
  if ps.pos < Array.length ps.toks then ps.toks.(ps.pos) else eof_tok

let advance ps = ps.pos <- ps.pos + 1

let parse_error ps msg =
  failwith (Printf.sprintf "%s at %s:%d" msg ps.file (cur ps).tline)

(* Skip newline tokens (used wherever the statement-continuation rule makes
   newlines insignificant: inside brackets, after an operator/'='/'->'/','
   or a form head still awaiting its block). *)
let skip_nl ps =
  while (cur ps).t = TNewline do advance ps done

(* Peek respecting newline significance: with [nl] true, newlines are
   transparent (and consumed — they can never matter again in that context). *)
let peek ps ~nl =
  if nl then skip_nl ps;
  cur ps

let peek2 ps =
  (* token after the current one, skipping nothing *)
  if ps.pos + 1 < Array.length ps.toks then ps.toks.(ps.pos + 1) else eof_tok

(* Expression context: [nl] — newlines transparent; [cond] — brace-free
   parse (an `if` condition: a top-level `{` may not start a map literal). *)
type ctx = { nl : bool; cond : bool }

let free_ctx = { nl = true; cond = false }

let err_block ps msg = parse_error ps msg

(* The reserved words that are grammar, not bindable names (§B.1). Kept for
   documentation; dispatch below is shape-driven (a reserved word whose
   expected opener does not follow parses as its symbol, exactly as an sexpr
   symbol in non-car position does). *)
let _reserved = [
  "and"; "assert"; "config"; "def"; "defmacro"; "delay"; "do"; "else"; "fn";
  "force"; "if"; "import"; "island"; "let"; "let*"; "load"; "load-module";
  "mod"; "module"; "needs"; "node"; "or"; "perform"; "quasiquote"; "quote";
  "reconcile"; "splice"; "unquote"; "with-caps"; "with-config"; "with-handler";
  "true"; "false"; "nil";
]

let infix_mul = ["*"; "/"; "mod"]
let infix_add = ["+"; "-"]
let infix_cmp = ["<"; ">"; "<="; ">="; "="]

(* Does [t] start an expression? (for `if`/`perform`-style head fallback) *)
let starts_expr t =
  match t with
  | TInt _ | TFloat _ | TString _ | TKeyword _ | TName _ | TCell _
  | TLParen | TLBracket -> true
  | _ -> false

let expect ps ~nl (t : btok) (what : string) =
  let k = peek ps ~nl in
  if k.t = t then advance ps
  else parse_error ps (Printf.sprintf "expected %s, got %s" what (string_of_btok k.t))

(* An infix-operator occurrence: a TName in [ops], with whitespace on BOTH
   sides (§B.1's frozen rule; `a ->b` is the identifier `->b`, and `(a)+ b`
   is not an application of '+'). *)
let peek_infix ps ~nl (ops : string list) : string option =
  let k = peek ps ~nl in
  match k.t with
  | TName s when List.mem s ops ->
      if k.glued then None
      else if (peek2 ps).glued then None
      else Some s
  | _ -> None

(* Bracket spread support *)
type bracket_elem = BElem of expr | BSpread of expr
(* Counter for fresh temp variables in try-block lowering *)
let try_counter = ref 0
let fresh_try_var () =
  incr try_counter;
  "__try_" ^ string_of_int !try_counter

type try_stmt = TryBind of string * expr | TryExpr of expr


let rec parse_expr ps (c : ctx) : expr =
  parse_pipe ps c

(* level 7: |> — loosest; left-associative; pure reader-level rewriting *)
and parse_pipe ps c =
  let left = ref (parse_or_level ps c) in
  let rec loop () =
    match peek_infix ps ~nl:c.nl ["|>"] with
    | Some _ ->
        advance ps;
        skip_nl ps;
        let rhs = parse_or_level ps { c with nl = c.nl } in
        (match rhs with
         | ESymbol _ -> left := EApply (rhs, [!left])
         | EApply (f, args) -> left := EApply (f, !left :: args)
         | _ ->
             parse_error ps
               "the right-hand side of |> must be an identifier or a call form");
        loop ()
    | None -> ()
  in
  loop ();
  !left

(* level 6: or — right-associative (reproduces the variadic desugar) *)
and parse_or_level ps c =
  let left = parse_and_level ps c in
  match peek_infix ps ~nl:c.nl ["or"] with
  | Some _ ->
      advance ps;
      skip_nl ps;
      let right = parse_or_level ps c in
      EIf (left, ELiteral (VBool true), right)
  | None -> left

(* level 5: and — right-associative *)
and parse_and_level ps c =
  let left = parse_cmp ps c in
  match peek_infix ps ~nl:c.nl ["and"] with
  | Some _ ->
      advance ps;
      skip_nl ps;
      let right = parse_and_level ps c in
      EIf (left, right, ELiteral (VBool false))
  | None -> left

(* level 4: comparisons — non-associative; chaining is a parse error *)
and parse_cmp ps c =
  let left = parse_add ps c in
  match peek_infix ps ~nl:c.nl infix_cmp with
  | Some op ->
      advance ps;
      skip_nl ps;
      let right = parse_add ps c in
      (match peek_infix ps ~nl:c.nl infix_cmp with
       | Some _ ->
           parse_error ps
             "comparison operators do not chain (use the call form, e.g. <(a, b, c))"
       | None -> ());
      EApply (ESymbol op, [left; right])
  | None -> left

(* level 3: + - — left-associative, strictly binary *)
and parse_add ps c =
  let left = ref (parse_mul ps c) in
  let rec loop () =
    match peek_infix ps ~nl:c.nl infix_add with
    | Some op ->
        advance ps;
        skip_nl ps;
        let right = parse_mul ps c in
        left := EApply (ESymbol op, [!left; right]);
        loop ()
    | None -> ()
  in
  loop ();
  !left

(* level 2: * / mod *)
and parse_mul ps c =
  let left = ref (parse_postfix ps c) in
  let rec loop () =
    match peek_infix ps ~nl:c.nl infix_mul with
    | Some op ->
        advance ps;
        skip_nl ps;
        let right = parse_postfix ps c in
        left := EApply (ESymbol op, [!left; right]);
        loop ()
    | None -> ()
  in
  loop ();
  !left

(* level 1: call postfix E(a, ...) and index postfix E[k] — left-associative *)
and parse_postfix ps c =
  let e = ref (parse_primary ps c) in
  let rec loop () =
    match (peek ps ~nl:c.nl).t with
    | TLParen ->
        advance ps;
        let args = parse_args ps in
        e := EApply (!e, args);
        loop ()
    | TLBracket ->
        (* L10: expr[index] — map or vector access *)
        advance ps;
        skip_nl ps;
        let idx = parse_expr ps free_ctx in
        expect ps ~nl:true TRBracket "']'";
        let accessor =
          match idx with
          | ELiteral (VInt _) -> "vector-get"
          | _ -> "hash-map-get"
        in
        e := EApply (ESymbol accessor, [!e; idx]);
        loop ()
    | _ -> ()
  in
  loop ();
  !e

(* comma-separated expressions up to ')' (consumed) *)
and parse_args ps : expr list =
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let e = parse_expr ps free_ctx in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop (e :: acc)
      | TRParen -> advance ps; List.rev (e :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    loop []
  end

(* ---- primaries and head forms ---- *)

and parse_primary ps c : expr =
  let k = cur ps in
  match k.t with
  | TEOF -> parse_error ps "unexpected end of input"
  | TNewline | TSemi ->
      parse_error ps "expected expression"
  | TRParen | TRBracket | TRBrace ->
      parse_error ps "unexpected closing delimiter"
  | TComma -> parse_error ps "unexpected comma"
  | TColon -> parse_error ps "unexpected colon"
  | TInt n -> advance ps; ELiteral (VInt n)
  | TFloat f -> advance ps; ELiteral (VFloat f)
  | TString s -> advance ps; ELiteral (VString s)
  | TKeyword kw -> advance ps; ELiteral (VKeyword kw)
  | TCell (head, s) ->
      advance ps;
      (* L47–L49: world-reads get visual identity; same lowered forms *)
      (match head with
       | "file" -> EApply (ESymbol "slurp", [ELiteral (VString s)])
       | "env" -> EApply (ESymbol "env-get", [ELiteral (VString s)])
       | "tree" -> EPerform ("tree-observe", [ELiteral (VString s)])
       | _ -> parse_error ps ("unknown cell literal head: " ^ head))
  | TLParen ->
      (* L8: grouping only; no AST node *)
      advance ps;
      skip_nl ps;
      let e = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      e
  | TLBracket ->
      (* L9: [e1, e2, ...] -> (list e1 e2 ...); lists are the default collection
         Spread: [a, ...rest] -> cons(a, rest); [a, b, ...rest] -> cons(a, cons(b, rest)) *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; EApply (ESymbol "list", []))
      else begin
        let elems = parse_bracket_elems ps in
        build_spread_list "list" "cons" elems
      end
  | TLBrace ->
      if c.cond then
        parse_error ps
          "a map literal used directly as a condition must be parenthesized"
      else parse_map_literal ps
  | TName "true" -> advance ps; ELiteral (VBool true)
  | TName "false" -> advance ps; ELiteral (VBool false)
  | TName "nil" -> advance ps; ELiteral VNil
  | TName n when String.length n > 0 && n.[0] = '$' ->
      (* $file("path"), $env("VAR"[,"default"]), $glob("pattern"),
         $probe("name"), $secret("path") — observation sigils *)
      let kind = String.sub n 1 (String.length n - 1) in
      advance ps;
      (match kind with
       | "file" ->
           advance ps;
           (match (peek ps ~nl:true).t with
            | TString p -> advance ps; expect ps ~nl:true TRParen "')'";
              EApply (ESymbol "slurp", [ELiteral (VString p)])
            | t -> parse_error ps ("$file expects a string path, got " ^ string_of_btok t))
       | "env" ->
           advance ps;
           skip_nl ps;
           (match (peek ps ~nl:true).t with
            | TString name ->
                advance ps;
                (match (peek ps ~nl:true).t with
                 | TComma ->
                     advance ps; skip_nl ps;
                     let d = parse_expr ps free_ctx in
                     expect ps ~nl:true TRParen "')'";
                     let v = EApply (ESymbol "env-get", [ELiteral (VString name)]) in
                     EIf (EApply (ESymbol "nil?", [v]), d, v)
                 | TRParen -> advance ps;
                     EApply (ESymbol "env-get", [ELiteral (VString name)])
                 | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t))
            | t -> parse_error ps ("$env expects a string name, got " ^ string_of_btok t))
       | "glob" ->
           advance ps;
           (match (peek ps ~nl:true).t with
            | TString p -> advance ps; expect ps ~nl:true TRParen "')'";
              EApply (ESymbol "list-dir", [ELiteral (VString p)])
            | t -> parse_error ps ("$glob expects a string pattern, got " ^ string_of_btok t))
       | "probe" ->
           advance ps;
           (match (peek ps ~nl:true).t with
            | TString name -> advance ps; expect ps ~nl:true TRParen "')'";
              EApply (ESymbol "probe", [ELiteral (VString name)])
            | t -> parse_error ps ("$probe expects a string name, got " ^ string_of_btok t))
       | "secret" ->
           advance ps;
           (match (peek ps ~nl:true).t with
            | TString p -> advance ps; expect ps ~nl:true TRParen "')'";
              EApply (ESymbol "slurp", [ELiteral (VString p)])
            | t -> parse_error ps ("$secret expects a string path, got " ^ string_of_btok t))
       | _ -> ESymbol n)
  | TName n -> parse_head ps c n

(* { k1 -> v1, k2 -> v2, ... } -> (hash-map k1 v1 k2 v2 ...)
   { base | k1 -> v1, k2 -> v2, ... } -> map-insert(map-insert(base, k1, v1), ...);
   cur = '{' *)
and parse_map_literal ps : expr =
  advance ps;
  skip_nl ps;
  if (cur ps).t = TRBrace then (advance ps; EApply (ESymbol "hash-map", []))
  else begin
    let first = parse_expr ps free_ctx in
    (* check if this is a map update: { base | k -> v, ... } *)
    (match peek_infix ps ~nl:true ["|"] with
     | Some _ ->
         advance ps;  (* consume '|' *)
         skip_nl ps;
         let rec updates acc =
           let key = parse_expr ps free_ctx in
           (match peek_infix ps ~nl:true ["->"] with
            | Some _ -> advance ps
            | None ->
                parse_error ps
                  ("expected '->' between map key and value, got "
                   ^ string_of_btok (peek ps ~nl:true).t));
           skip_nl ps;
           let v = parse_expr ps free_ctx in
           let acc = EApply (ESymbol "map-insert", [acc; key; v]) in
           match (peek ps ~nl:true).t with
           | TComma -> advance ps; skip_nl ps; updates acc
           | TRBrace -> advance ps; acc
           | t -> parse_error ps ("expected ',' or '}', got " ^ string_of_btok t)
         in
         updates first
     | None ->
         (* normal map literal: the first expr is a key *)
         (match peek_infix ps ~nl:true ["->"] with
          | Some _ -> advance ps
          | None ->
              parse_error ps
                ("expected '->' between map key and value, got "
                 ^ string_of_btok (peek ps ~nl:true).t));
         skip_nl ps;
         let first_val = parse_expr ps free_ctx in
         let rec loop acc =
           match (peek ps ~nl:true).t with
           | TComma ->
               advance ps; skip_nl ps;
               let key = parse_expr ps free_ctx in
               (match peek_infix ps ~nl:true ["->"] with
                | Some _ -> advance ps
                | None ->
                    parse_error ps
                      ("expected '->' between map key and value, got "
                       ^ string_of_btok (peek ps ~nl:true).t));
               skip_nl ps;
               let v = parse_expr ps free_ctx in
               loop (v :: key :: acc)
           | TRBrace -> advance ps; acc
           | t -> parse_error ps ("expected ',' or '}', got " ^ string_of_btok t)
         in
         let rest = loop [] in
         EApply (ESymbol "hash-map", first :: first_val :: List.rev rest))
  end

(* A brace block `{ stmt; ... }`; returns the raw statement list.
   cur must be '{' (callers may skip_nl first — a head awaiting its block
   continues across newlines). *)
and parse_block_stmts ps : expr list =
  expect ps ~nl:false TLBrace "'{'";
  parse_stmts ps ~closing:TRBrace ~what:"block"

(* newline/';'-separated statements until [closing] (consumed) *)
and parse_stmts ps ~(closing : btok) ~(what : string) : expr list =
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    let k = cur ps in
    if k.t = closing then (advance ps; List.rev acc)
    else if k.t = TEOF then
      (if closing = TEOF then List.rev acc
       else parse_error ps ("unterminated " ^ what))
    else begin
      let e = parse_expr ps { nl = false; cond = false } in
      (match (cur ps).t with
       | TNewline | TSemi -> ()
       | t when t = closing -> ()
       | TEOF -> ()
       | t ->
           parse_error ps
             ("expected newline or ';' between statements, got "
              ^ string_of_btok t));
      loop (e :: acc)
    end
  in
  loop []

(* block rule ⟦stmts⟧, sharing reader.ml's exact desugar + LAW-4 check;
   the error position is the token after the block, as in reader.ml *)
and block_body_of ps (stmts : expr list) : expr =
  Desugar.block_body ~err:(fun m -> err_block ps m) stmts

and check_defs ps (stmts : expr list) : expr list =
  Desugar.check_block_defs ~err:(fun m -> err_block ps m) stmts

(* parse `{ ... }` (after optional newlines) and apply the block rule *)
and parse_block_body ps : expr =
  skip_nl ps;
  let stmts = parse_block_stmts ps in
  block_body_of ps stmts

(* Parenthesized parameter list `(p [: ty], ...)`; consumes through ')'.
   Annotation types parse at call level (never across '=' or ','). *)
and parse_paren_params ps : (string * expr option) list =
  expect ps ~nl:false TLParen "'('";
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let k = peek ps ~nl:true in
      match k.t with
      | TName p ->
          advance ps;
          let ty =
            if (cur ps).t = TColon then begin
              advance ps;
              skip_nl ps;
              Some (parse_postfix ps free_ctx)
            end else None
          in
          let acc = (p, ty) :: acc in
          (match (peek ps ~nl:true).t with
           | TComma -> advance ps; skip_nl ps; loop acc
           | TRParen -> advance ps; List.rev acc
           | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t))
      | t -> parse_error ps ("expected parameter symbol, got " ^ string_of_btok t)
    in
    loop []
  end

(* optional `: ty` return annotation (after the parameter list) *)
and parse_ret_ty ps : expr option =
  if (cur ps).t = TColon then begin
    advance ps;
    skip_nl ps;
    Some (parse_postfix ps { nl = false; cond = true })
  end else None

(* ---- head-word dispatch (shape-driven; a reserved word whose opener does
   not follow denotes its symbol, mirroring sexpr non-car positions) ---- *)

and parse_head ps c (n : string) : expr =
  let next_t = (peek2 ps).t in
  match n with
  | "fn" when next_t = TLParen ->
      advance ps;
      let line = (cur ps).tline in
      let locate e = ELocated ((ps.file, line), e) in
      let params = parse_paren_params ps in
      let ret_ty = parse_ret_ty ps in
      let body = parse_block_body ps in
      let names, body' = Desugar.assemble_fn_body locate params ret_ty body in
      EFn (names, body')
  | "def" when (match next_t with TName _ -> true | _ -> false) ->
      (* def f(p, ...) [: ty] { body } — L29–L31 *)
      advance ps;
      let line = (cur ps).tline in
      let locate e = ELocated ((ps.file, line), e) in
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "def requires a parameter list: def name(params) { ... }";
      let params = parse_paren_params ps in
      let ret_ty = parse_ret_ty ps in
      let body = parse_block_body ps in
      let names, body' = Desugar.assemble_fn_body locate params ret_ty body in
      EDef (name, names, body')
  | "node" when next_t = TLBrace ->
      (* L32: node { E... } -> (node ⟦E...⟧) *)
      advance ps;
      skip_nl ps;
      let stmts = parse_block_stmts ps in
      ENode (block_body_of ps stmts)
  | "node" when (match next_t with TName _ -> true | _ -> false) ->
      advance ps;
      let line = (cur ps).tline in
      let locate e = ELocated ((ps.file, line), e) in
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      (match (cur ps).t with
       | TLParen ->
           (* L34/L35: node f(p...) [: ty] [needs I1, I2] { body } *)
           let params = parse_paren_params ps in
           let ret_ty = parse_ret_ty ps in
           let needs =
             match (cur ps).t with
             | TName "needs" when not (cur ps).glued ->
                 advance ps;
                 skip_nl ps;
                 let rec items acc =
                   let e = parse_expr ps { nl = false; cond = true } in
                   match (peek ps ~nl:false).t with
                   | TComma -> advance ps; skip_nl ps; items (e :: acc)
                   | _ -> List.rev (e :: acc)
                 in
                 Some (items [])
             | _ -> None
           in
           let body = parse_block_body ps in
           let body =
             match needs with
             | None -> body
             | Some items ->
                 let lower_item = function
                   | EApply (ESymbol "fs.read", [e]) -> needs_restrict e "ro"
                   | EApply (ESymbol "fs.write", [e]) -> needs_restrict e "wo"
                   | EApply (ESymbol "fs.rw", [e]) -> needs_restrict e "rw"
                   | e -> e
                 in
                 let lowered = List.map lower_item items in
                 let cap = match lowered with
                   | [one] -> one
                   | several -> EApply (ESymbol "cap-compose", several)
                 in
                 EWithCaps (cap, body)
           in
           let names, body' = Desugar.assemble_fn_body locate params ret_ty body in
           EDefNode (name, names, body')
       | TLBrace ->
           (* L33: node name { E... } -> (defnode name ⟦E...⟧) *)
           skip_nl ps;
           let stmts = parse_block_stmts ps in
           EDefValue (name, locate (ENode (block_body_of ps stmts)))
       | t ->
           parse_error ps ("malformed node definition: expected '(' or '{', got "
                           ^ string_of_btok t))
  | "do" when next_t = TLBrace ->
      (* L36: do { s... } -> (do s...) — the raw list, as in sexprs *)
      advance ps;
      let stmts = parse_block_stmts ps in
      EDo (check_defs ps stmts)
  | "if" when starts_expr next_t ->
      parse_if ps
  | "cond" when next_t = TLBrace ->
      (* cond { test1 => result1; test2 => result2; ... } — multi-way conditional
         lowers to nested EIf; the last arm `true => result` is the else *)
      advance ps;
      skip_nl ps;
      expect ps ~nl:false TLBrace "'{'";
      let rec skip_seps () =
        match (cur ps).t with
        | TNewline | TSemi -> advance ps; skip_seps ()
        | _ -> ()
      in
      let rec parse_arms acc =
        skip_seps ();
        if (cur ps).t = TRBrace then (advance ps; List.rev acc)
        else if (cur ps).t = TEOF then
          parse_error ps "unterminated cond block"
        else begin
          let test = parse_expr ps { nl = false; cond = false } in
          (match peek_infix ps ~nl:true ["=>"] with
           | Some _ -> advance ps
           | None ->
               parse_error ps "cond arm must be `test => result`");
          skip_nl ps;
          let result = parse_expr ps { nl = false; cond = false } in
          skip_seps ();
          parse_arms ((test, result) :: acc)
        end
      in
      let arms = parse_arms [] in
      let rec lower arms =
        match arms with
        | [] -> ELiteral VNil
        | [(test, result)] ->
            if test = ESymbol "true" || test = ELiteral (VBool true)
            then result
            else EIf (test, result, ELiteral VNil)
        | (test, result) :: rest ->
            EIf (test, result, lower rest)
      in
      lower arms
  | "try" when next_t = TLBrace ->
      (* try { name <- expr; ...; final-expr } — error propagation
         Each `name <- expr` unwraps [:ok, v] or propagates [:err, e]. *)
      advance ps;
      skip_nl ps;
      let stmts = parse_try_stmts ps in
      lower_try_block stmts
  | "collect" when next_t = TLBrace ->
      (* collect { expr; expr; ... } — evaluate each, collect [:ok, v]/[:err, e] *)
      advance ps;
      skip_nl ps;
      let stmts = parse_block_stmts ps in
      lower_collect_block stmts
  | "fenced" when (match next_t with TKeyword _ -> true | _ -> false) ->
      (* fenced :kind { key -> value, ... } -> perform fenced(:kind, map) *)
      advance ps;  (* consume 'fenced' *)
      let kind = (match (cur ps).t with
        | TKeyword kw -> advance ps; ELiteral (VKeyword kw)
        | _ -> parse_error ps "fenced requires a keyword kind, e.g. fenced :email { ... }")
      in
      skip_nl ps;
      let spec = parse_map_literal ps in
      EPerform ("fenced", [kind; spec])
  | "match" when starts_expr next_t ->
      (* match expr { pat1 => body1; pat2 => body2; ... } *)
      advance ps;  (* consume 'match' *)
      let scrutinee = parse_expr ps { nl = false; cond = true } in
      skip_nl ps;
      expect ps ~nl:false TLBrace "'{'";
      let arms = parse_match_arms ps in
      EMatch (scrutinee, arms)
  | "with" when next_t = TLBrace ->
      (* with { caps: C, config: M, handler H: fn ... } { body }
         Lowers to nested EWithCaps, EWithConfig, EWithHandler in canonical order. *)
      advance ps;  (* consume 'with' *)
      skip_nl ps;
      expect ps ~nl:false TLBrace "'{'";
      let rec parse_clauses caps_opt config_opt handlers =
        (* skip separators *)
        let rec skip_seps () =
          match (cur ps).t with
          | TNewline | TSemi | TComma -> advance ps; skip_seps ()
          | _ -> ()
        in
        skip_seps ();
        if (cur ps).t = TRBrace then (advance ps; (caps_opt, config_opt, List.rev handlers))
        else if (cur ps).t = TEOF then parse_error ps "unterminated with block"
        else begin
          match (cur ps).t with
          | TName "caps" when (peek2 ps).t = TColon ->
              advance ps; advance ps; skip_nl ps;
              let cap = parse_expr ps { nl = false; cond = false } in
              if caps_opt <> None then parse_error ps "duplicate caps: clause in with block";
              parse_clauses (Some cap) config_opt handlers
          | TName "config" when (peek2 ps).t = TColon ->
              advance ps; advance ps; skip_nl ps;
              let m = parse_expr ps { nl = false; cond = false } in
              if config_opt <> None then parse_error ps "duplicate config: clause in with block";
              parse_clauses caps_opt (Some m) handlers
          | TName "handler" ->
              advance ps;
              let hname =
                match (cur ps).t with
                | TName s -> s
                | TKeyword k -> k
                | t -> parse_error ps ("expected handler name, got " ^ string_of_btok t)
              in
              advance ps;
              if (cur ps).t <> TColon then
                parse_error ps "expected ':' after handler name in with block";
              advance ps; skip_nl ps;
              let h = parse_expr ps { nl = false; cond = false } in
              parse_clauses caps_opt config_opt ((hname, h) :: handlers)
          | t -> parse_error ps ("expected caps:, config:, or handler in with block, got " ^ string_of_btok t)
        end
      in
      let (caps_opt, config_opt, handlers) = parse_clauses None None [] in
      let body = parse_block_body ps in
      (* Nest in canonical order: caps (outermost), config, handlers (innermost) *)
      let body =
        match handlers with
        | [] -> body
        | _ -> EWithHandler (handlers, body)
      in
      let body =
        match config_opt with
        | None -> body
        | Some m -> EWithConfig (m, body)
      in
      let body =
        match caps_opt with
        | None -> body
        | Some cap -> EWithCaps (cap, body)
      in
      body
  | n when String.length n > 0 && n.[0] = '@' ->
      (* @attr(args) annotation on following definition *)
      let attr = String.sub n 1 (String.length n - 1) in
      advance ps;
      let attr_args =
        if (cur ps).t = TLParen then begin
          advance ps;
          let args = parse_args ps in
          args
        end else []
      in
      skip_nl ps;
      (* Parse the following definition and apply the attribute *)
      let def = parse_primary ps c in
      (match attr, attr_args with
       | "cache", [] ->
           (match def with
            | EDef (name, params, body) -> EDef (name, params, ENode body)
            | _ -> parse_error ps "@cache can only be applied to a def")
       | "needs", _ ->
           (match def with
            | EDefNode _ | ENode _ ->
                (* @needs is handled inside node syntax; passthrough for now *)
                def
            | _ -> parse_error ps "@needs can only be applied to a node")
       | "reads", _ -> def  (* @reads is documentation-only; passthrough *)
       | "deprecated", [ELiteral (VString msg)] ->
           (match def with
            | EDef (name, params, body) ->
                let warn = EApply (ESymbol "print", [ELiteral (VString ("deprecated: " ^ name ^ " — " ^ msg))]) in
                EDef (name, params, EDo [warn; body])
            | _ -> def)
       | _ ->
           (* unknown attribute: passthrough the def unchanged *)
           def)
  | "let" ->
      (match next_t with
       | TName "=" ->
           parse_error ps "let binding name is missing"
       | TName _ when (ps.pos + 2 < Array.length ps.toks
                       && (match ps.toks.(ps.pos + 2).t with
                           | TName "=" -> true
                           | TColon -> true
                           | _ -> false)) ->
           (* L21/L22: let x = E (a type annotation here is a parse error) *)
           advance ps;
           let line = (cur ps).tline in
           let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
           advance ps;
           if (cur ps).t = TColon then
             parse_error ps
               ("a `let " ^ name ^ " = ...` binding takes no type annotation \
                 (use let (" ^ name ^ ": ty = ...) { ... })");
           advance ps;  (* '=' *)
           skip_nl ps;
           let rhs = parse_expr ps c in
           EDefValue (name, ELocated ((ps.file, line), rhs))
       | TLParen ->
           (* L23/L24: let (x [: ty] = e, ...) { body... } *)
           advance ps;
           let binds = parse_binding_group ps ~allow_ty:true in
           let body = parse_block_body ps in
           ELet (binds, body)
       | _ -> advance ps; ESymbol "let")
  | "let*" when next_t = TLParen ->
      advance ps;
      let binds = parse_binding_group ps ~allow_ty:false in
      let body = parse_block_body ps in
      ELetStar (binds, body)
  | "quote" when next_t = TLBrace ->
      (* L56: quote { F } — one form only *)
      advance ps;
      let stmts = parse_block_stmts ps in
      (match stmts with
       | [f] -> EQuote f
       | _ -> parse_error ps "quote { ... } must contain exactly one form")
  | "quasiquote" when next_t = TLBrace ->
      (* L57: quasiquote { F } — quasiquote-mode read of the lowering *)
      advance ps;
      (match parse_qq_block_items ps with
       | [f] -> EApply (ESymbol "quasiquote", [f])
       | _ -> parse_error ps "quasiquote { ... } must contain exactly one form")
  | "force" when next_t = TLParen ->
      advance ps; parse_one_arg_form ps (fun e -> EForce e) "force"
  | "delay" when next_t = TLParen ->
      advance ps; parse_one_arg_form ps (fun e -> EDelay e) "delay"
  | "import" when next_t = TLParen ->
      advance ps; parse_one_arg_form ps (fun e -> EImport e) "import"
  | "perform" when (match next_t with TName _ -> true | _ -> false) ->
      (* L41: perform name(a, ...) *)
      advance ps;
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "perform requires an argument list: perform name(args)";
      advance ps;
      let args = parse_args ps in
      EPerform (name, args)
  | "with-caps" when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let cap = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      let body = parse_block_body ps in
      EWithCaps (cap, body)
  | "with-config" when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let m = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      let body = parse_block_body ps in
      EWithConfig (m, body)
  | "with-handler" when next_t = TLParen ->
      (* L42: with-handler(n1 = h1, n2 = h2) { body... } *)
      advance ps; advance ps;
      skip_nl ps;
      let rec pairs acc =
        let name =
          match (peek ps ~nl:true).t with
          | TName s -> advance ps; s
          | TKeyword k -> advance ps; k
          | t -> parse_error ps ("handler name must be a symbol or keyword, got "
                                 ^ string_of_btok t)
        in
        (match (peek ps ~nl:true).t with
         | TName "=" -> advance ps
         | t -> parse_error ps ("expected '=' after handler name, got "
                                ^ string_of_btok t));
        skip_nl ps;
        let h = parse_expr ps free_ctx in
        match (peek ps ~nl:true).t with
        | TComma -> advance ps; skip_nl ps; pairs ((name, h) :: acc)
        | TRParen -> advance ps; List.rev ((name, h) :: acc)
        | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
      in
      let handlers = if (peek ps ~nl:true).t = TRParen
                     then (advance ps; []) else pairs [] in
      let body = parse_block_body ps in
      EWithHandler (handlers, body)
  | "module" when next_t = TLBrace ->
      (* L51: module { forms... } *)
      advance ps;
      let stmts = parse_block_stmts ps in
      EModule (check_defs ps stmts)
  | "load" when next_t = TLParen ->
      advance ps; advance ps;
      (match (peek ps ~nl:true).t with
       | TString p ->
           advance ps;
           expect ps ~nl:true TRParen "')'";
           ELoad p
       | _ -> parse_error ps "load expects a string path")
  | "load-module" when next_t = TLParen ->
      advance ps; advance ps;
      (match (peek ps ~nl:true).t with
       | TString p ->
           advance ps;
           expect ps ~nl:true TRParen "')'";
           ELoadModule p
       | _ -> parse_error ps "load-module expects a string path")
  | "island" when next_t = TLParen ->
      (* L55: island("URI"[, "PIN"]) — braces spell URIs as strings *)
      advance ps; advance ps;
      (match (peek ps ~nl:true).t with
       | TString uri ->
           advance ps;
           let pin =
             match (peek ps ~nl:true).t with
             | TComma ->
                 advance ps;
                 (match (peek ps ~nl:true).t with
                  | TString p -> advance ps; Some p
                  | t -> parse_error ps ("island pin must be a string, got "
                                         ^ string_of_btok t))
             | _ -> None
           in
           expect ps ~nl:true TRParen "')'";
           EIsland (uri, pin)
       | t -> parse_error ps ("island expects a string URI, got " ^ string_of_btok t))
  | "config" when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let key = parse_expr ps free_ctx in
      (match (peek ps ~nl:true).t with
       | TComma ->
           advance ps; skip_nl ps;
           let d = parse_expr ps free_ctx in
           expect ps ~nl:true TRParen "')'";
           EConfig (key, Some d)
       | TRParen -> advance ps; EConfig (key, None)
       | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t))
  | "assert" when next_t = TLParen ->
      (* L46: assert(C[, M]) — shared desugar; the line is the condition's
         first token's, exactly as the sexpr reader's peek_line is *)
      advance ps; advance ps;
      skip_nl ps;
      let line = (cur ps).tline in
      let cond = parse_expr ps free_ctx in
      (match (peek ps ~nl:true).t with
       | TComma ->
           advance ps; skip_nl ps;
           let m = parse_expr ps free_ctx in
           expect ps ~nl:true TRParen "')'";
           Desugar.desugar_assert ~file:ps.file ~line cond (Some m)
       | TRParen ->
           advance ps;
           Desugar.desugar_assert ~file:ps.file ~line cond None
       | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t))
  | "defmacro" when (match next_t with TName _ -> true | _ -> false) ->
      (* L60: defmacro name(p...) { s1; s2; ... } — exactly the application
         shape macro.ml's match_defmacro recognizes (never EDo-wrapped) *)
      advance ps;
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "defmacro requires a parameter list: defmacro name(params) { ... }";
      let params = parse_paren_params ps in
      let params =
        List.map (fun (p, ty) ->
          match ty with
          | None -> ESymbol p
          | Some _ -> parse_error ps "defmacro parameters take no type annotation")
          params
      in
      skip_nl ps;
      let stmts = parse_block_stmts ps in
      EApply (ESymbol "defmacro", EApply (ESymbol name, params) :: stmts)
  | "reconcile" when next_t = TLBrace ->
      (* L61: identity sugar naming the final-value map *)
      advance ps;
      parse_map_literal ps
  | ("and" | "or") when next_t = TLParen ->
      (* special-form heads applied in call position parse as their special
         forms, mirroring the sexpr reader's car-symbol dispatch (§B.1) *)
      advance ps; advance ps;
      let args = parse_args ps in
      if n = "and" then Desugar.desugar_and args else Desugar.desugar_or args
  | ("quote" | "quasiquote" | "unquote" | "splice") when next_t = TLParen ->
      (* call-position spelling: a plain application (what the lowered
         quasiquote AST prints back as; `unquote(E)`/`splice(E)` are given
         meaning only inside quasiquote{} — elsewhere they reach the
         evaluator as ordinary unbound applications, like a stray `,` form
         in sexprs) *)
      advance ps; advance ps;
      let args = parse_args ps in
      EApply (ESymbol n, args)
  | "vec" when next_t = TLBracket ->
      (* vec[e1, e2, ...] -> (vector e1 e2 ...); spread: vec[a, ...rest] *)
      advance ps;  (* consume "vec" *)
      advance ps;  (* consume "[" *)
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; EApply (ESymbol "vector", []))
      else begin
        let elems = parse_bracket_elems ps in
        build_spread_list "vector" "cons" elems
      end
  | _ ->
      (* not a form occurrence: the word denotes its symbol (L6/L7) *)
      advance ps;
      ESymbol n

and needs_restrict (e : expr) (mode : string) : expr =
  EApply (ESymbol "cap-restrict",
          [EApply (ESymbol "current-capabilities", []); e;
           ELiteral (VKeyword mode)])


and parse_bracket_elems ps : bracket_elem list =
  let rec loop acc =
    match (cur ps).t with
    | TName s when String.length s >= 3 && String.sub s 0 3 = "..." ->
        advance ps;
        let target =
          if String.length s > 3 then
            (* suffix is part of the token: ...rest *)
            ESymbol (String.sub s 3 (String.length s - 3))
          else
            (* bare ..., parse next expression *)
            parse_expr ps free_ctx
        in
        (match (peek ps ~nl:true).t with
         | TComma -> advance ps; skip_nl ps; loop (BSpread target :: acc)
         | TRBracket -> advance ps; List.rev (BSpread target :: acc)
         | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
    | _ ->
        let e = parse_expr ps free_ctx in
        (match (peek ps ~nl:true).t with
         | TComma -> advance ps; skip_nl ps; loop (BElem e :: acc)
         | TRBracket -> advance ps; List.rev (BElem e :: acc)
         | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
  in
  loop []

and build_spread_list (ctor : string) (cons_name : string)
    (elems : bracket_elem list) : expr =
  let rec has_spread = function
    | [] -> false | BSpread _ :: _ -> true | BElem _ :: rest -> has_spread rest
  in
  if not (has_spread elems) then
    let args = List.map (function BElem e -> e | BSpread e -> e) elems in
    EApply (ESymbol ctor, args)
  else
    (* Split at the spread: prefix elements consed onto the spread tail *)
    let rec split acc = function
      | [] -> (List.rev acc, EApply (ESymbol ctor, []))
      | BSpread e :: rest ->
          if rest = [] then (List.rev acc, e)
          else failwith "spread (...) only supported at end of list/vector"
      | BElem e :: rest -> split (e :: acc) rest
    in
    let (prefix, tail) = split [] elems in
    List.fold_right (fun e acc -> EApply (ESymbol cons_name, [e; acc])) prefix tail


(* Parse statements inside a try { } block.
   Returns list; each item is either `TryBind (name, rhs)` for a
   `name <- expr` bind, or `TryExpr expr` for a normal statement. *)
and parse_try_stmts ps : try_stmt list =
  expect ps ~nl:false TLBrace "'{'";
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    let k = cur ps in
    if k.t = TRBrace then (advance ps; List.rev acc)
    else if k.t = TEOF then parse_error ps "unterminated try block"
    else begin
      match k.t with
      | TName name when not k.glued && not (peek2 ps).glued && (peek2 ps).t = TName "<-" ->
          advance ps;  (* consume name *)
          advance ps;  (* consume <- *)
          skip_nl ps;
          let rhs = parse_expr ps { nl = false; cond = false } in
          loop (TryBind (name, rhs) :: acc)
      | TName "let" ->
          (* Check for `let name = expr?` — treat as TryBind *)
          advance ps;  (* consume 'let' *)
          (match (cur ps).t with
           | TName name ->
               advance ps;
               if (cur ps).t = TName "=" then begin
                 advance ps; skip_nl ps;
                 let rhs = parse_expr ps { nl = false; cond = false } in
                 if (cur ps).t = TName "?" && (cur ps).glued then begin
                   advance ps;  (* consume ? *)
                   loop (TryBind (name, rhs) :: acc)
                 end else
                   parse_error ps "in try block, use `let name = expr?` or `name <- expr` to unwrap"
               end else
                 parse_error ps "expected `let name = expr?` in try block"
           | _ ->
               parse_error ps "expected variable name after `let` in try block")
      | _ ->
          let e = parse_expr ps { nl = false; cond = false } in
          (* Check for postfix ? operator on bare expression *)
          let e =
            if (cur ps).t = TName "?" && (cur ps).glued then begin
              advance ps;  (* consume ? *)
              let tmp = fresh_try_var () in
              let tmp_sym = ESymbol tmp in
              let ok_kw = ELiteral (VKeyword "ok") in
              let car_of x = EApply (ESymbol "car", [x]) in
              let cdr_of x = EApply (ESymbol "cdr", [x]) in
              ELet ([tmp, e],
                    EIf (EApply (ESymbol "=", [car_of tmp_sym; ok_kw]),
                         car_of (cdr_of tmp_sym),
                         tmp_sym))
            end else e
          in
          loop (TryExpr e :: acc)
    end
  in
  loop []

(* Lower a try block's statements into a nested if-chain.
   Each `name <- expr` becomes a check for [:ok, v] / [:err, e].
   The last statement is the result (when all propagations succeed). *)
and lower_try_block (stmts : try_stmt list) : expr =
  let ok_kw = ELiteral (VKeyword "ok") in
  let car_of e = EApply (ESymbol "car", [e]) in
  let cdr_of e = EApply (ESymbol "cdr", [e]) in
  let rec build = function
    | [] -> ok_kw  (* default: :ok (nil result) *)
    | [TryExpr e] -> e
    | TryExpr e :: rest ->
        EDo [e; build rest]
    | TryBind (name, rhs) :: rest ->
        let tmp = fresh_try_var () in
        let tmp_sym = ESymbol tmp in
        let ok_branch =
          ELet ([name, car_of (cdr_of tmp_sym)], build rest)
        in
        let err_branch = tmp_sym in
        ELet ([tmp, rhs],
              EIf (EApply (ESymbol "=", [car_of tmp_sym; ok_kw]),
                   ok_branch, err_branch))
  in
  build stmts

(* Lower a collect block: evaluate all expressions, collect results into a list.
   Each expression should return [:ok, v] or [:err, e].
   Returns [:ok, values] if all succeeded, or [:err, errors] if any failed. *)
and lower_collect_block (stmts : expr list) : expr =
  let results = EApply (ESymbol "list", stmts) in
  EApply (ESymbol "collect-results", [results])

(* Parse match arms inside { } — each arm is `pattern => body` separated by newlines/; *)
and parse_match_arms ps : (Types.pattern * expr) list =
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    if (cur ps).t = TRBrace then (advance ps; List.rev acc)
    else if (cur ps).t = TEOF then parse_error ps "unterminated match block"
    else begin
      let pat = parse_pattern ps in
      (match peek_infix ps ~nl:true ["=>"] with
       | Some _ -> advance ps
       | None -> parse_error ps "match arm must be `pattern => body`");
      skip_nl ps;
      let body = parse_expr ps { nl = false; cond = false } in
      loop ((pat, body) :: acc)
    end
  in
  loop []

(* Parse a single pattern *)
and parse_pattern ps : Types.pattern =
  let k = cur ps in
  match k.t with
  | TName "_" -> advance ps; Types.PWildcard
  | TName "true" -> advance ps; Types.PLiteral (VBool true)
  | TName "false" -> advance ps; Types.PLiteral (VBool false)
  | TName "nil" -> advance ps; Types.PLiteral VNil
  | TName n when n.[0] >= 'a' && n.[0] <= 'z' ->
      (* Lowercase name: variable pattern *)
      advance ps; Types.PVariable n
  | TName n -> advance ps; Types.PVariable n  (* any name is a variable for now *)
  | TInt i -> advance ps; Types.PLiteral (VInt i)
  | TFloat f -> advance ps; Types.PLiteral (VFloat f)
  | TString s -> advance ps; Types.PLiteral (VString s)
  | TKeyword kw -> advance ps; Types.PLiteral (VKeyword kw)
  | TLBracket ->
      (* List pattern: [p1, p2, ...rest] *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; Types.PList ([], None))
      else begin
        let rec loop_pats acc =
          let k = cur ps in
          match k.t with
          | TName s when String.length s >= 3 && String.sub s 0 3 = "..." ->
              (* Spread must be the last element; bind the remainder. *)
              advance ps;
              let rest_name = String.sub s 3 (String.length s - 3) in
              if rest_name = "" then
                parse_error ps "spread pattern '...' must be followed by a name or '_'";
              let rest_pat = if rest_name = "_" then Types.PWildcard else Types.PVariable rest_name in
              skip_nl ps;
              expect ps ~nl:true TRBracket "']' after spread pattern";
              (List.rev acc, Some rest_pat)
          | _ ->
              let p = parse_pattern ps in
              skip_nl ps;
              match (cur ps).t with
              | TComma -> advance ps; skip_nl ps; loop_pats (p :: acc)
              | TRBracket -> advance ps; (List.rev (p :: acc), None)
              | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t)
        in
        let pats, rest = loop_pats [] in
        Types.PList (pats, rest)
      end
  | TLParen ->
      (* Tagged pattern: (:ok v) or just grouping *)
      advance ps;
      skip_nl ps;
      (match (cur ps).t with
       | TKeyword tag ->
           advance ps;
           let rec loop_pats acc =
             if (cur ps).t = TRParen then (advance ps; List.rev acc)
             else begin
               let p = parse_pattern ps in
               loop_pats (p :: acc)
             end
           in
           Types.PTagged (tag, loop_pats [])
       | _ ->
           let p = parse_pattern ps in
           expect ps ~nl:true TRParen "')'";
           p)
  | _ ->
      parse_error ps ("expected pattern, got " ^ string_of_btok k.t)
and parse_one_arg_form ps (mk : expr -> expr) (what : string) : expr =
  advance ps;  (* '(' *)
  skip_nl ps;
  let e = parse_expr ps free_ctx in
  (match (peek ps ~nl:true).t with
   | TRParen -> advance ps
   | t -> parse_error ps (Printf.sprintf "%s takes exactly one expression, got %s"
                            what (string_of_btok t)));
  mk e

(* if C { T... } [else if C2 { ... }]* [else { E... }] — L37–L39.
   cur = the `if` name token. The condition is parsed brace-free (Go-style). *)
and parse_if ps : expr =
  advance ps;  (* 'if' *)
  let cond = parse_expr ps { nl = false; cond = true } in
  let then_b = parse_block_body ps in
  let else_e =
    (* A newline may legitimately separate `}` from `else` (§ the pragmatic
       reformatter always joins them onto one line, but the parser must
       accept the split form too). Peek past newlines; only actually
       consume them if `else` is what follows — otherwise the newline is
       left alone so it can still terminate this statement. *)
    let save = ps.pos in
    skip_nl ps;
    match (cur ps).t with
    | TName "else" ->
        advance ps;
        (match (cur ps).t with
         | TName "if" -> parse_if ps
         | TLBrace -> parse_block_body ps
         | t -> parse_error ps ("expected 'if' or '{' after else, got "
                                ^ string_of_btok t))
    | _ -> ps.pos <- save; ELiteral VNil
  in
  EIf (cond, then_b, else_e)

(* let/let* binding group `(x [: ty] = e, ...)`; cur = '(' *)
and parse_binding_group ps ~(allow_ty : bool) : (string * expr) list =
  advance ps;  (* '(' *)
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let name =
        match (peek ps ~nl:true).t with
        | TName s -> advance ps; s
        | t -> parse_error ps ("binding name must be a symbol, got "
                               ^ string_of_btok t)
      in
      let ty =
        if (cur ps).t = TColon then begin
          if not allow_ty then
            parse_error ps "let* bindings take no type annotation";
          advance ps;
          skip_nl ps;
          Some (parse_postfix ps free_ctx)
        end else None
      in
      (match (peek ps ~nl:true).t with
       | TName "=" -> advance ps
       | t -> parse_error ps ("expected '=' in binding, got " ^ string_of_btok t));
      skip_nl ps;
      let v = parse_expr ps free_ctx in
      let v' = match ty with Some t -> ETyped (v, t) | None -> v in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop ((name, v') :: acc)
      | TRParen -> advance ps; List.rev ((name, v') :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    loop []
  end

(* ---- Quasiquote mode (L57–L59) ----

   A brace form denotes the s-expression DATA of its lowering: atoms quoted,
   `[ ... ]` list literals as cons chains (L9 — the same VNil-terminated value
   the equivalent code builds, NOT a vector; see A2), maps as hash-map builds.
   unquote(E)/splice(E) escape to a normally-parsed E. Desugars
   (and/or/assert/...) never apply here: quoted data is data.

   Coverage: atoms, names (reserved words included), calls, the infix operator
   levels, grouping, list literals, maps, quote/quasiquote nesting, fn/def/if/
   let/let*/do/perform/with-caps/with-config/with-handler/module/import/force/
   delay/config/load/load-module/island/assert/node and cell literals. A3
   added: try { ... } (parse_qq_try_stmts/qq_lower_try_block, the same
   nested let/if data lower_try_block builds as real nodes), match E { pat
   => body; ... } (parse_qq_match_arms/parse_qq_pattern, the same arm/
   pattern data quote_to_value's EMatch case builds — value_to_expr gained
   a matching "match" case + value_to_pattern, since EMatch is a first-
   class AST node with no prior quote_to_value inverse), postfix m[k]
   index (parse_qq_postfix's TLBracket arm, same vector-get/hash-map-get
   accessor choice as parse_postfix), and list-literal spread
   `[a, ...rest]` (parse_qq_primary's TLBracket arm, same cons(a, rest)
   shape build_spread_list builds).

   S5 ergonomics (was S1's deviation #2): `unquote(E)` is now legal in a
   let/let* BINDING NAME and a def's FUNCTION NAME (parse_qq_name_slot) —
   the two "computed name" shapes real macro templates need: a gensym'd
   hygienic temporary (`let (unquote(g) = unquote(a)) { if unquote(g) ... }`)
   and a macro-generated def name (`def unquote(name)(x) { ... }`).
   splice(e) already worked in any list/argument/block position (parse_qq_*
   already routed every element through parse_qq, which dispatches splice at
   parse_qq_head) — it needed no reader change, only exercising. A3's match
   arms are the one exception to "every element routes through parse_qq":
   patterns are always literal (parse_qq_pattern, not parse_qq) — the same
   judgment as parse_qq_name_slot's param-list restriction below, and an
   unquote(...) in pattern position is a worded parse error, not silently
   dropped.

   Still parse errors, deliberately NOT lifted (documented in SPEC.md
   Appendix B.7, not fuzzed, no existing/rewritten macro test needs them):
   defmacro/needs inside quasiquote{} (a macro that itself generates a macro
   definition or a `needs` clause is not a shape any test exercises); node
   DEFINITIONS `node name { ... }` / `node f(p) { ... }` (only the bare node
   EXPRESSION `node { E }` is data-representable) — the workaround for all
   three is the pre-S5 one: build the application via `list`/`cons` calls
   directly, exactly as `apply_macro`'s callers always could. Type
   annotations (fn/def param types, let binding types, return types) inside
   quasiquote{} are also still parse errors — no macro test needs a
   templated annotation, and annotations are a separate AST node (`ETyped`),
   not plain quoted-symbol data, so representing one as quasiquote DATA
   would need a new data convention, not just a parser extension. *)

and qq_nil : expr = EQuote (ELiteral VNil)

and qq_chain (items : expr list) : expr =
  qq_chain_tail items qq_nil

(* Like qq_chain, but the cons-chain ends in [tail] instead of qq_nil — the
   list-literal SPREAD case (A3): `[a, ...rest]`'s data must be the SAME
   `cons(a, rest)` shape the ordinary bracket-literal spread builds
   (build_spread_list), not always nil-terminated. *)
and qq_chain_tail (items : expr list) (tail : expr) : expr =
  List.fold_right (fun e acc -> EApply (ESymbol "cons", [e; acc])) items tail

and qq_sym (s : string) : expr = EQuote (ESymbol s)

and parse_qq ps : expr =
  parse_qq_pipe ps

and parse_qq_pipe ps =
  let left = parse_qq_or ps in
  match peek_infix ps ~nl:true ["|>"] with
  | Some _ -> parse_error ps "|> is not representable inside quasiquote { ... }"
  | None -> left

and parse_qq_or ps =
  let left = parse_qq_and ps in
  match peek_infix ps ~nl:true ["or"] with
  | Some _ ->
      advance ps; skip_nl ps;
      let right = parse_qq_or ps in
      qq_chain [qq_sym "or"; left; right]
  | None -> left

and parse_qq_and ps =
  let left = parse_qq_cmp ps in
  match peek_infix ps ~nl:true ["and"] with
  | Some _ ->
      advance ps; skip_nl ps;
      let right = parse_qq_and ps in
      qq_chain [qq_sym "and"; left; right]
  | None -> left

and parse_qq_cmp ps =
  let left = parse_qq_add ps in
  match peek_infix ps ~nl:true infix_cmp with
  | Some op ->
      advance ps; skip_nl ps;
      let right = parse_qq_add ps in
      qq_chain [qq_sym op; left; right]
  | None -> left

and parse_qq_add ps =
  let left = ref (parse_qq_mul ps) in
  let rec loop () =
    match peek_infix ps ~nl:true infix_add with
    | Some op ->
        advance ps; skip_nl ps;
        let right = parse_qq_mul ps in
        left := qq_chain [qq_sym op; !left; right];
        loop ()
    | None -> ()
  in
  loop (); !left

and parse_qq_mul ps =
  let left = ref (parse_qq_postfix ps) in
  let rec loop () =
    match peek_infix ps ~nl:true infix_mul with
    | Some op ->
        advance ps; skip_nl ps;
        let right = parse_qq_postfix ps in
        left := qq_chain [qq_sym op; !left; right];
        loop ()
    | None -> ()
  in
  loop (); !left

and parse_qq_postfix ps =
  let e = ref (parse_qq_primary ps) in
  let rec loop () =
    (* nl:false (A3 fix), not nl:true: a bare `(`/`[` that starts the NEXT
       line must never be swallowed as THIS primary's postfix call/index —
       exactly the hazard the normal grammar's parse_postfix avoids by
       threading its caller's `c.nl` (statement/body positions pass
       nl=false) instead of hardcoding transparency. A qq match arm's body
       (`pat => body`) or a qq try statement's rhs sits in exactly such a
       position: `v + 1` on one line followed by `[:err, e] => 0` on the
       next must parse as two separate things, not `(v + 1)[...]`. *)
    match (peek ps ~nl:false).t with
    | TLParen ->
        advance ps;
        let args = parse_qq_args ps in
        e := qq_chain (!e :: args);
        loop ()
    | TLBracket ->
        (* A3: m[k] index — mirror parse_postfix's TLBracket arm (:431-445)
           exactly, including its accessor choice: a SYNTACTICALLY literal
           int index lowers to vector-get, anything else to hash-map-get.
           In qq, a literal int index parses (via parse_qq_primary's TInt
           case) to exactly `EQuote (ELiteral (VInt _))` — no other qq
           shape produces that, so checking for it here is the same
           decision the normal reader makes on the unwrapped `idx`. *)
        advance ps;
        skip_nl ps;
        let idx = parse_qq ps in
        expect ps ~nl:true TRBracket "']'";
        let accessor =
          match idx with
          | EQuote (ELiteral (VInt _)) -> "vector-get"
          | _ -> "hash-map-get"
        in
        e := qq_chain [qq_sym accessor; !e; idx];
        loop ()
    | _ -> ()
  in
  loop (); !e

and parse_qq_args ps : expr list =
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let e = parse_qq ps in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop (e :: acc)
      | TRParen -> advance ps; List.rev (e :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    loop []
  end

(* a block in quasiquote data position: 1 stmt -> itself; else (do ...) *)
and parse_qq_block_one ps : expr =
  let items = parse_qq_block_items ps in
  match items with
  | [one] -> one
  | items -> qq_chain (qq_sym "do" :: items)

and parse_qq_block_items ps : expr list =
  skip_nl ps;
  expect ps ~nl:false TLBrace "'{'";
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    match (cur ps).t with
    | TRBrace -> advance ps; List.rev acc
    | TEOF -> parse_error ps "unterminated block in quasiquote"
    | _ ->
        let e = parse_qq ps in
        (match (cur ps).t with
         | TNewline | TSemi | TRBrace -> ()
         | t -> parse_error ps ("expected newline or ';' between statements, got "
                                ^ string_of_btok t));
        loop (e :: acc)
  in
  loop []

and parse_qq_primary ps : expr =
  let k = cur ps in
  match k.t with
  | TEOF -> parse_error ps "unexpected end of input in quasiquote"
  | TRParen | TRBracket | TRBrace ->
      parse_error ps "unexpected closing delimiter in quasiquote"
  | TComma -> parse_error ps "unexpected comma in quasiquote"
  | TColon -> parse_error ps "unexpected colon in quasiquote"
  | TNewline | TSemi -> parse_error ps "expected expression in quasiquote"
  | TInt n -> advance ps; EQuote (ELiteral (VInt n))
  | TFloat f -> advance ps; EQuote (ELiteral (VFloat f))
  | TString s -> advance ps; EQuote (ELiteral (VString s))
  | TKeyword kw -> advance ps; EQuote (ELiteral (VKeyword kw))
  | TCell (head, s) ->
      advance ps;
      let low = match head with
        | "file" -> [qq_sym "slurp"; EQuote (ELiteral (VString s))]
        | "env" -> [qq_sym "env-get"; EQuote (ELiteral (VString s))]
        | "tree" -> [qq_sym "perform"; qq_sym "tree-observe";
                     EQuote (ELiteral (VString s))]
        | _ -> parse_error ps ("unknown cell literal head: " ^ head)
      in
      qq_chain low
  | TLParen ->
      (* grouping (L8): no data node of its own *)
      advance ps;
      skip_nl ps;
      let e = parse_qq ps in
      expect ps ~nl:true TRParen "')'";
      e
  | TLBracket ->
      (* L9: [ ... ] is the list literal — lists are the default collection.
         The template must build the SAME value the equivalent code builds
         (a cons-chain list, VNil-terminated), not a vector (A2). A3 adds
         surface spread `[a, ...rest]`: mirrors parse_bracket_elems /
         build_spread_list (:1209-1253) exactly, only routing every
         element (and the spread target) through parse_qq instead of
         parse_expr, so unquote/splice work in any position — including
         `...unquote(xs)` to splice a REAL runtime list value as the tail,
         the realistic use (a bare `...rest` quotes the symbol `rest`
         itself, same as any other unlifted qq atom). *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; qq_nil)
      else begin
        let rec loop acc =
          match (cur ps).t with
          | TName s when String.length s >= 3 && String.sub s 0 3 = "..." ->
              advance ps;
              let target =
                if String.length s > 3 then
                  qq_sym (String.sub s 3 (String.length s - 3))
                else
                  parse_qq ps
              in
              (match (peek ps ~nl:true).t with
               | TComma -> advance ps; skip_nl ps; loop (BSpread target :: acc)
               | TRBracket -> advance ps; List.rev (BSpread target :: acc)
               | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
          | _ ->
              let e = parse_qq ps in
              (match (peek ps ~nl:true).t with
               | TComma -> advance ps; skip_nl ps; loop (BElem e :: acc)
               | TRBracket -> advance ps; List.rev (BElem e :: acc)
               | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
        in
        let elems = loop [] in
        let has_spread = List.exists (function BSpread _ -> true | _ -> false) elems in
        if not has_spread then
          qq_chain (List.map (function BElem e -> e | BSpread e -> e) elems)
        else
          let rec split acc = function
            | [] -> (List.rev acc, qq_nil)
            | BSpread e :: rest ->
                if rest = [] then (List.rev acc, e)
                else parse_error ps
                       "spread '...' is only supported at the end of a list in quasiquote"
            | BElem e :: rest -> split (e :: acc) rest
          in
          let (prefix, tail) = split [] elems in
          qq_chain_tail prefix tail
      end
  | TLBrace ->
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBrace then (advance ps; EApply (ESymbol "hash-map", []))
      else begin
        let rec loop acc =
          let key = parse_qq ps in
          (match peek_infix ps ~nl:true ["->"] with
           | Some _ -> advance ps
           | None -> parse_error ps "expected '->' between map key and value");
          skip_nl ps;
          let v = parse_qq ps in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; loop (v :: key :: acc)
          | TRBrace -> advance ps; List.rev (v :: key :: acc)
          | t -> parse_error ps ("expected ',' or '}', got " ^ string_of_btok t)
        in
        EApply (ESymbol "hash-map", loop [])
      end
  | TName "true" -> advance ps; EQuote (ELiteral (VBool true))
  | TName "false" -> advance ps; EQuote (ELiteral (VBool false))
  | TName "nil" -> advance ps; EQuote (ELiteral VNil)
  | TName n -> parse_qq_head ps n

(* S5 ergonomics: a "name slot" inside a qq_head shape (a let/let* binding
   name, or a def's function name) — ordinarily a bare identifier, quoted
   verbatim (qq_sym), OR `unquote(E)`, lifting S1's deviation #2 to the
   extent macros actually need it: the canonical gensym hygiene pattern
   `let (unquote(g) = unquote(a)) { ... }` (a macro's temp binding, named at
   expansion time) and a macro-computed def name (`def unquote(name)(x)
   { ... }`, e.g. `defadder`). Parameter LISTS stay literal-names-only —
   unlifted; no macro test needs a computed parameter name, and
   parse_paren_params is shared with the non-quasiquote parser, so
   extending it would risk the real (non-qq) grammar. *)
and parse_qq_name_slot ps ~(what : string) : expr =
  match (peek ps ~nl:true).t with
  | TName "unquote" when (peek2 ps).t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let e = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      EApply (ESymbol "list", [EQuote (ESymbol "unquote"); e])
  | TName s -> advance ps; qq_sym s
  | t -> parse_error ps (what ^ " must be a symbol or unquote(...), got "
                         ^ string_of_btok t)

and parse_qq_head ps (n : string) : expr =
  let next_t = (peek2 ps).t in
  match n with
  | "unquote" when next_t = TLParen ->
      (* ,E — E is evaluated NORMALLY *)
      advance ps; advance ps;
      skip_nl ps;
      let e = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      EApply (ESymbol "list", [EQuote (ESymbol "unquote"); e])
  | "splice" when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let e = parse_expr ps free_ctx in
      expect ps ~nl:true TRParen "')'";
      EApply (ESymbol "list", [EQuote (ESymbol "unquote-splicing"); e])
  | "quote" when next_t = TLBrace ->
      advance ps;
      (match parse_qq_block_items ps with
       | [f] -> EQuote f
       | _ -> parse_error ps "quote { ... } must contain exactly one form")
  | "quasiquote" when next_t = TLBrace ->
      advance ps;
      (match parse_qq_block_items ps with
       | [f] -> EApply (ESymbol "quasiquote", [f])
       | _ -> parse_error ps "quasiquote { ... } must contain exactly one form")
  | "fn" when next_t = TLParen ->
      advance ps;
      let params = parse_paren_params ps in
      let param_data =
        qq_chain (List.map (fun (p, ty) ->
          match ty with
          | None -> qq_sym p
          | Some _ -> parse_error ps
                        "type annotations are not representable inside quasiquote")
          params)
      in
      let body = parse_qq_block_items ps in
      qq_chain (qq_sym "fn" :: param_data :: body)
  | "def" when (match next_t with TName _ -> true | _ -> false) ->
      advance ps;
      let name_expr = parse_qq_name_slot ps ~what:"def name" in
      if (cur ps).t <> TLParen then
        parse_error ps "def requires a parameter list: def name(params) { ... }";
      let params = parse_paren_params ps in
      let head =
        qq_chain (name_expr
                  :: List.map (fun (p, ty) ->
                       match ty with
                       | None -> qq_sym p
                       | Some _ -> parse_error ps
                                     "type annotations are not representable inside quasiquote")
                       params)
      in
      let body = parse_qq_block_items ps in
      qq_chain (qq_sym "def" :: head :: body)
  | "node" when next_t = TLBrace ->
      advance ps;
      let b = parse_qq_block_one ps in
      qq_chain [qq_sym "node"; b]
  | "do" when next_t = TLBrace ->
      advance ps;
      let items = parse_qq_block_items ps in
      qq_chain (qq_sym "do" :: items)
  | "if" when starts_expr next_t ->
      advance ps;
      let cond = parse_qq_cond ps in
      let then_b = parse_qq_block_one ps in
      (* Same else-across-a-newline lookahead as parse_if: only consume the
         newline(s) if `else` actually follows. *)
      let save = ps.pos in
      skip_nl ps;
      (match (cur ps).t with
       | TName "else" ->
           advance ps;
           (match (cur ps).t with
            | TName "if" ->
                let e = parse_qq_head ps "if" in
                qq_chain [qq_sym "if"; cond; then_b; e]
            | TLBrace ->
                let e = parse_qq_block_one ps in
                qq_chain [qq_sym "if"; cond; then_b; e]
            | t -> parse_error ps ("expected 'if' or '{' after else, got "
                                   ^ string_of_btok t))
       | _ -> ps.pos <- save; qq_chain [qq_sym "if"; cond; then_b])
  | "try" when next_t = TLBrace ->
      (* A3: try { ... } — build the SAME nested let/if DATA shape
         lower_try_block builds as real expr nodes (:1322-1342), just with
         qq_chain/qq_sym instead of ELet/EIf/EApply, and every
         bind/statement rhs routed through parse_qq (so unquote/splice
         work in a try statement's expression position). fresh_try_var is
         the SAME global counter the normal path uses (reset once per
         top-level form, read_string's try_counter := 0) — sharing it here
         keeps A1's determinism guarantee (a form's LAW-20 hash depends
         only on the form, not on how many try blocks preceded it) intact
         whether the try block was written directly or inside a
         quasiquote template. *)
      advance ps;
      skip_nl ps;
      let stmts = parse_qq_try_stmts ps in
      qq_lower_try_block stmts
  | "match" when starts_expr next_t ->
      (* A3: match E { pat => body; ... } — build the SAME DATA shape
         quote_to_value's OWN EMatch case builds (types.ml, `(match
         scrutinee ((pat1 body1) ...))`, arm patterns encoded exactly as
         quote_pattern does), so a macro-expanded template reconstructs a
         real EMatch via the matching value_to_expr "match" case added
         alongside this (A3 also had to add that inverse — it didn't
         exist before, since EMatch is a first-class AST node, not sugar
         over existing forms, unlike try/if/do). Patterns stay fully
         literal (parse_qq_pattern) — no unquote in pattern position, same
         judgment as parse_qq_name_slot's param-list restriction: no macro
         test needs a computed pattern, and quote_pattern's tagged
         encoding has no unquote convention of its own to lift. Arm bodies
         and the scrutinee route through parse_qq, so unquote/splice work
         there. *)
      advance ps;
      let scrutinee = parse_qq ps in
      skip_nl ps;
      expect ps ~nl:false TLBrace "'{'";
      let arms = parse_qq_match_arms ps in
      qq_chain [qq_sym "match"; scrutinee; arms]
  | ("let" | "let*") when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let rec binds acc =
        if (cur ps).t = TRParen then (advance ps; List.rev acc)
        else begin
          let name_expr = parse_qq_name_slot ps ~what:"binding name" in
          if (cur ps).t = TColon then
            parse_error ps "type annotations are not representable inside quasiquote";
          (match (peek ps ~nl:true).t with
           | TName "=" -> advance ps
           | t -> parse_error ps ("expected '=' in binding, got " ^ string_of_btok t));
          skip_nl ps;
          let v = parse_qq ps in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; binds (v :: name_expr :: acc)
          | TRParen -> advance ps; List.rev (v :: name_expr :: acc)
          | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
        end
      in
      let flat = binds [] in
      let body = parse_qq_block_items ps in
      qq_chain (qq_sym n :: EApply (ESymbol "vector", flat) :: body)
  | "perform" when (match next_t with TName _ -> true | _ -> false) ->
      advance ps;
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "perform requires an argument list: perform name(args)";
      advance ps;
      let args = parse_qq_args ps in
      qq_chain (qq_sym "perform" :: qq_sym name :: args)
  | ("with-caps" | "with-config") when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let e = parse_qq ps in
      expect ps ~nl:true TRParen "')'";
      let body = parse_qq_block_items ps in
      qq_chain (qq_sym n :: e :: body)
  | "with-handler" when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let rec pairs acc =
        if (cur ps).t = TRParen then (advance ps; List.rev acc)
        else begin
          let name_e =
            match (peek ps ~nl:true).t with
            | TName s -> advance ps; qq_sym s
            | TKeyword k -> advance ps; EQuote (ELiteral (VKeyword k))
            | t -> parse_error ps ("handler name must be a symbol or keyword, got "
                                   ^ string_of_btok t)
          in
          (match (peek ps ~nl:true).t with
           | TName "=" -> advance ps
           | t -> parse_error ps ("expected '=' after handler name, got "
                                  ^ string_of_btok t));
          skip_nl ps;
          let h = parse_qq ps in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; pairs (h :: name_e :: acc)
          | TRParen -> advance ps; List.rev (h :: name_e :: acc)
          | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
        end
      in
      let flat = pairs [] in
      let body = parse_qq_block_items ps in
      qq_chain (qq_sym "with-handler" :: EApply (ESymbol "vector", flat) :: body)
  | "module" when next_t = TLBrace ->
      advance ps;
      let items = parse_qq_block_items ps in
      qq_chain (qq_sym "module" :: items)
  | ("import" | "force" | "delay") when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let e = parse_qq ps in
      expect ps ~nl:true TRParen "')'";
      qq_chain [qq_sym n; e]
  | ("config" | "assert" | "load" | "load-module" | "island"
    | "and" | "or") when next_t = TLParen ->
      advance ps; advance ps;
      let args = parse_qq_args ps in
      qq_chain (qq_sym n :: args)
  | "reconcile" when next_t = TLBrace ->
      advance ps;
      (* data of the lowering: a hash-map build *)
      parse_qq_primary ps
  | ("defmacro" | "needs") ->
      parse_error ps (n ^ " is not representable inside quasiquote { ... }")
  | _ ->
      advance ps;
      EQuote (ESymbol n)

(* condition of `if` inside quasiquote: brace-free, one qq expression *)
and parse_qq_cond ps : expr =
  (* reuse the qq precedence chain; a top-level '{' simply stops it *)
  parse_qq ps

(* A3: try { ... } inside quasiquote — parse_try_stmts's exact grammar
   (:1259-1317), with every rhs/bare-expr routed through parse_qq instead
   of parse_expr (unquote/splice work in a statement's expression
   position; bind NAMES stay bare identifiers, same convention as
   parse_qq_name_slot — no macro test needs a computed try-bind name). *)
and parse_qq_try_stmts ps : try_stmt list =
  expect ps ~nl:false TLBrace "'{'";
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    let k = cur ps in
    if k.t = TRBrace then (advance ps; List.rev acc)
    else if k.t = TEOF then parse_error ps "unterminated try block in quasiquote"
    else begin
      match k.t with
      | TName name when not k.glued && not (peek2 ps).glued && (peek2 ps).t = TName "<-" ->
          advance ps;  (* consume name *)
          advance ps;  (* consume <- *)
          skip_nl ps;
          let rhs = parse_qq ps in
          loop (TryBind (name, rhs) :: acc)
      | TName "let" ->
          advance ps;  (* consume 'let' *)
          (match (cur ps).t with
           | TName name ->
               advance ps;
               if (cur ps).t = TName "=" then begin
                 advance ps; skip_nl ps;
                 let rhs = parse_qq ps in
                 if (cur ps).t = TName "?" && (cur ps).glued then begin
                   advance ps;  (* consume ? *)
                   loop (TryBind (name, rhs) :: acc)
                 end else
                   parse_error ps
                     "in try block, use `let name = expr?` or `name <- expr` to unwrap"
               end else
                 parse_error ps "expected `let name = expr?` in try block"
           | _ ->
               parse_error ps "expected variable name after `let` in try block")
      | _ ->
          let e = parse_qq ps in
          (* bare `expr?` — same postfix-? unwrap sugar as the normal path,
             built as DATA: `(let [g rhs] (if (= (car g) :ok) (car (cdr g)) g))`. *)
          let e =
            if (cur ps).t = TName "?" && (cur ps).glued then begin
              advance ps;  (* consume ? *)
              let tmp = fresh_try_var () in
              let tmp_sym = qq_sym tmp in
              let ok_kw = EQuote (ELiteral (VKeyword "ok")) in
              qq_chain
                [qq_sym "let"; EApply (ESymbol "vector", [qq_sym tmp; e]);
                 qq_chain
                   [qq_sym "if";
                    qq_chain [qq_sym "="; qq_chain [qq_sym "car"; tmp_sym]; ok_kw];
                    qq_chain [qq_sym "car"; qq_chain [qq_sym "cdr"; tmp_sym]];
                    tmp_sym]]
            end else e
          in
          loop (TryExpr e :: acc)
    end
  in
  loop []

(* A3: the qq analogue of lower_try_block (:1322-1342) — SAME nested
   let/if structure, built as quoted DATA (qq_chain/qq_sym) instead of
   literal ELet/EIf/EApply nodes, so `value_to_expr` (or the runtime
   `quasiquote` builtin, for a non-macro use) reconstructs exactly what
   the ordinary `try { ... }` parse produces. *)
and qq_lower_try_block (stmts : try_stmt list) : expr =
  let ok_kw = EQuote (ELiteral (VKeyword "ok")) in
  let car_of e = qq_chain [qq_sym "car"; e] in
  let cdr_of e = qq_chain [qq_sym "cdr"; e] in
  let rec build = function
    | [] -> ok_kw
    | [TryExpr e] -> e
    | TryExpr e :: rest -> qq_chain [qq_sym "do"; e; build rest]
    | TryBind (name, rhs) :: rest ->
        let tmp = fresh_try_var () in
        let tmp_sym = qq_sym tmp in
        let ok_branch =
          qq_chain [qq_sym "let"; EApply (ESymbol "vector", [qq_sym name; car_of (cdr_of tmp_sym)]);
                    build rest]
        in
        let err_branch = tmp_sym in
        qq_chain [qq_sym "let"; EApply (ESymbol "vector", [qq_sym tmp; rhs]);
                  qq_chain [qq_sym "if";
                            qq_chain [qq_sym "="; car_of tmp_sym; ok_kw];
                            ok_branch; err_branch]]
  in
  build stmts

(* A3: a single pattern inside a qq `match` arm — parse_pattern's exact
   grammar (:1375-1440), built as the quoted-DATA shape quote_pattern
   produces for that pattern (types.ml :860-875: `_`/`(lit v)`/`(var
   "name")`/`(list (pats...) rest)`/`(tagged "tag" pats...)`), so
   value_to_pattern (its inverse, added alongside the "match" case in
   value_to_expr) reconstructs the identical Types.pattern after macro
   expansion. Deliberately NOT unquote-aware (see the "match" arm's
   comment) — an unquote(...) here falls to the trailing parse_error,
   worded to say so rather than a generic "expected pattern". *)
and parse_qq_pattern ps : expr =
  let k = cur ps in
  match k.t with
  | TName "_" -> advance ps; qq_sym "_"
  | TName "true" -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VBool true))]
  | TName "false" -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VBool false))]
  | TName "nil" -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral VNil)]
  | TName "unquote" ->
      parse_error ps
        "patterns are always literal inside quasiquote { ... }: unquote(...) \
         is not supported in match-pattern position"
  | TName n -> advance ps; qq_chain [qq_sym "var"; EQuote (ELiteral (VString n))]
  | TInt i -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VInt i))]
  | TFloat f -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VFloat f))]
  | TString s -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VString s))]
  | TKeyword kw -> advance ps; qq_chain [qq_sym "lit"; EQuote (ELiteral (VKeyword kw))]
  | TLBracket ->
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then
        (advance ps; qq_chain [qq_sym "list"; qq_nil; qq_nil])
      else begin
        let rec loop_pats acc =
          let k = cur ps in
          match k.t with
          | TName s when String.length s >= 3 && String.sub s 0 3 = "..." ->
              advance ps;
              let rest_name = String.sub s 3 (String.length s - 3) in
              if rest_name = "" then
                parse_error ps "spread pattern '...' must be followed by a name or '_'";
              let rest_pat =
                if rest_name = "_" then qq_sym "_"
                else qq_chain [qq_sym "var"; EQuote (ELiteral (VString rest_name))]
              in
              skip_nl ps;
              expect ps ~nl:true TRBracket "']' after spread pattern";
              (List.rev acc, rest_pat)
          | _ ->
              let p = parse_qq_pattern ps in
              skip_nl ps;
              (match (cur ps).t with
               | TComma -> advance ps; skip_nl ps; loop_pats (p :: acc)
               | TRBracket -> advance ps; (List.rev (p :: acc), qq_nil)
               | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
        in
        let pats, rest = loop_pats [] in
        qq_chain [qq_sym "list"; qq_chain pats; rest]
      end
  | TLParen ->
      advance ps;
      skip_nl ps;
      (match (cur ps).t with
       | TKeyword tag ->
           advance ps;
           let rec loop_pats acc =
             if (cur ps).t = TRParen then (advance ps; List.rev acc)
             else begin
               let p = parse_qq_pattern ps in
               loop_pats (p :: acc)
             end
           in
           qq_chain (qq_sym "tagged" :: EQuote (ELiteral (VString tag)) :: loop_pats [])
       | _ ->
           let p = parse_qq_pattern ps in
           expect ps ~nl:true TRParen "')'";
           p)
  | _ ->
      parse_error ps ("expected pattern, got " ^ string_of_btok k.t)

(* A3: match arms inside quasiquote — parse_match_arms's grammar
   (:1352-1372), built as a qq list of (pattern body) 2-element arms,
   exactly the shape quote_to_value's EMatch case builds for `arms`. *)
and parse_qq_match_arms ps : expr =
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    if (cur ps).t = TRBrace then (advance ps; qq_chain (List.rev acc))
    else if (cur ps).t = TEOF then parse_error ps "unterminated match block in quasiquote"
    else begin
      let pat = parse_qq_pattern ps in
      (match peek_infix ps ~nl:true ["=>"] with
       | Some _ -> advance ps
       | None -> parse_error ps "match arm must be `pattern => body`");
      skip_nl ps;
      let body = parse_qq ps in
      loop (qq_chain [pat; body] :: acc)
    end
  in
  loop []

(* ---- Public API ---- *)

(* Read brace-surface source text into top-level forms, each ELocated at the
   line of its first token — exactly Reader.read_string's wrapping. *)
let read_string ?(source : string = "<?>") (input : string) : expr list =
  let toks = lex ~file:source input in
  let ps = { toks = Array.of_list toks; pos = 0; file = source } in
  let result = ref [] in
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop () =
    skip_seps ();
    match (cur ps).t with
    | TEOF -> ()
    | _ ->
        (* A1: fresh temp-var numbering per top-level form, so a form's
           LAW-20 hash depends only on the form (and its location), never on
           how many `try` blocks were parsed earlier in the process/file. *)
        try_counter := 0;
        let line = (cur ps).tline in
        let e = parse_expr ps { nl = false; cond = false } in
        (match (cur ps).t with
         | TNewline | TSemi | TEOF -> ()
         | t ->
             parse_error ps
               ("expected newline or ';' between statements, got "
                ^ string_of_btok t));
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

(* ---- Extension dispatch (M7 S3: flipped; M7 S4: `-e` joins the default) ----

   `.pp` and `.ppb` read with the brace reader (`.pp` is now the default
   surface; `.ppb` remains a permanent alias — tests/054's fixtures use it).
   `.ppl` ("the AST form") reads with the sexpr reader — sexpr is demoted
   from "the syntax" to "the AST", still fully supported forever (it is the
   macro layer: `quote`/`defmacro` still traffic in sexpr data). The reader's
   own "<?>" default label — reached ONLY by `pp -e` (repl.ml's
   execute_string/execute_string_bytecode, called with no ~source, i.e. no
   real file at all) — now also reads braces, per M7 S4 "-e takes braces"
   (docs/M7-SYNTAX.md). Synthetic glue source tags main.ml builds for itself
   (e.g. "<stdlib:list.pp>", "<domain-glue:fs>" — literally sexpr text,
   `(load ...)`) are NOT this label and keep falling through to the sexpr
   reader untouched. The interactive REPL no longer reaches this dispatcher
   at all (repl.ml calls the brace reader directly; see needs_more_input
   below for its multi-line-continuation counterpart).
   [path] chooses the reader; [source] is the location label (when
   omitted, both readers' "<?>" default applies, preserving e.g.
   load-module's existing label behavior). *)

let file_uses_braces (path : string) : bool =
  Filename.check_suffix path ".pp" || Filename.check_suffix path ".ppb"
  || path = "<?>"

let read_dispatch ?(source : string option) ~(path : string) (input : string)
    : expr list =
  match source with
  | Some s ->
      if file_uses_braces path then read_string ~source:s input
      else Reader.read_string ~source:s input
  | None ->
      if file_uses_braces path then read_string input
      else Reader.read_string input

(* ---- REPL multi-line continuation (M7 S4) ----

   Whether [input] is still an open form that needs more lines before it can
   be read — used by repl.ml's read_form to decide whether to keep
   accumulating under the "..> " prompt. Reused rather than reimplemented:
   attempt the SAME parse the REPL will do to actually evaluate the input,
   and classify the failure. A form still open always fails by running out
   of tokens partway through — an unterminated string (the lexer's own
   "unterminated string"/"unterminated escape"), a block/quasiquote reading
   past its last token ("unterminated <what>"/"unterminated block in
   quasiquote"), or the parser wanting one more token and finding none
   (every "expected X, got <eof>"/"unexpected end of input[...]" message —
   string_of_btok TEOF = "<eof>", and parse_primary's bare-EOF case says
   "unexpected end of input"). This is the reader's actual bracket-nesting
   AND infix/statement-continuation logic (skip_nl's transparency, e.g. a
   trailing "+ " or a dangling `let`/`if`/`def` header awaiting its block) —
   reimplementing it as a standalone bracket-counter would have to
   rediscover every one of those "awaiting a block/paren/comma" shapes by
   hand and inevitably drift from the grammar above. A genuine syntax error
   (e.g. a stray extra ')') fails WITHOUT any of these markers, so it is
   handed to the REPL's normal error path instead of stalling the prompt. *)
let looks_incomplete (msg : string) : bool =
  let contains sub =
    let ls = String.length sub and lm = String.length msg in
    let rec go i = i + ls <= lm && (String.sub msg i ls = sub || go (i + 1)) in
    go 0
  in
  contains "<eof>" || contains "unterminated" || contains "unexpected end of input"

let needs_more_input ?(source : string = "<repl>") (input : string) : bool =
  try ignore (read_string ~source input); false
  with
  | Failure msg -> looks_incomplete msg
  | _ -> false
