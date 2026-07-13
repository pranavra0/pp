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

(* level 1: call postfix E(a, ...) — left-associative: f(x)(y) = ((f x) y) *)
and parse_postfix ps c =
  let e = ref (parse_primary ps c) in
  let rec loop () =
    match (peek ps ~nl:c.nl).t with
    | TLParen ->
        advance ps;
        let args = parse_args ps in
        e := EApply (!e, args);
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
      (* L9: [e1, e2, ...] -> (vector e1 e2 ...) *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; EApply (ESymbol "vector", []))
      else begin
        let rec loop acc =
          let e = parse_expr ps free_ctx in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; loop (e :: acc)
          | TRBracket -> advance ps; List.rev (e :: acc)
          | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t)
        in
        EApply (ESymbol "vector", loop [])
      end
  | TLBrace ->
      if c.cond then
        parse_error ps
          "a map literal used directly as a condition must be parenthesized"
      else parse_map_literal ps
  | TName "true" -> advance ps; ELiteral (VBool true)
  | TName "false" -> advance ps; ELiteral (VBool false)
  | TName "nil" -> advance ps; ELiteral VNil
  | TName n -> parse_head ps c n

(* { k1 -> v1, k2 -> v2, ... } -> (hash-map k1 v1 k2 v2 ...); cur = '{' *)
and parse_map_literal ps : expr =
  advance ps;
  skip_nl ps;
  if (cur ps).t = TRBrace then (advance ps; EApply (ESymbol "hash-map", []))
  else begin
    let rec loop acc =
      let key = parse_expr ps free_ctx in
      (match peek_infix ps ~nl:true ["->"] with
       | Some _ -> advance ps
       | None ->
           parse_error ps
             ("expected '->' between map key and value, got "
              ^ string_of_btok (peek ps ~nl:true).t));
      skip_nl ps;
      let v = parse_expr ps free_ctx in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop (v :: key :: acc)
      | TRBrace -> advance ps; List.rev (v :: key :: acc)
      | t -> parse_error ps ("expected ',' or '}', got " ^ string_of_btok t)
    in
    EApply (ESymbol "hash-map", loop [])
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
  | _ ->
      (* not a form occurrence: the word denotes its symbol (L6/L7) *)
      advance ps;
      ESymbol n

and needs_restrict (e : expr) (mode : string) : expr =
  EApply (ESymbol "cap-restrict",
          [EApply (ESymbol "current-capabilities", []); e;
           ELiteral (VKeyword mode)])

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
    match (cur ps).t with
    | TName "else" ->
        advance ps;
        (match (cur ps).t with
         | TName "if" -> parse_if ps
         | TLBrace -> parse_block_body ps
         | t -> parse_error ps ("expected 'if' or '{' after else, got "
                                ^ string_of_btok t))
    | _ -> ELiteral VNil
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
   lists as cons chains, vectors/maps as vector/hash-map builds — exactly the
   AST reader.ml's parse_qq_* emit for the equivalent sexpr text. unquote(E)/
   splice(E) escape to a normally-parsed E. Desugars (and/or/assert/...) never
   apply here: quoted data is data.

   Coverage: atoms, names (reserved words included), calls, the infix operator
   levels, grouping, vectors, maps, quote/quasiquote nesting, fn/def/if/
   let/let*/do/perform/with-caps/with-config/with-handler/module/import/force/
   delay/config/load/load-module/island/assert/node and cell literals.
   defmacro/needs/node-definitions inside quasiquote{} are parse errors
   (S1 scope; no existing program quasiquotes them). *)

and qq_nil : expr = EQuote (ELiteral VNil)

and qq_chain (items : expr list) : expr =
  List.fold_right (fun e acc -> EApply (ESymbol "cons", [e; acc])) items qq_nil

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
    match (peek ps ~nl:true).t with
    | TLParen ->
        advance ps;
        let args = parse_qq_args ps in
        e := qq_chain (!e :: args);
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
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; EApply (ESymbol "vector", []))
      else begin
        let rec loop acc =
          let e = parse_qq ps in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; loop (e :: acc)
          | TRBracket -> advance ps; List.rev (e :: acc)
          | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t)
        in
        EApply (ESymbol "vector", loop [])
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
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "def requires a parameter list: def name(params) { ... }";
      let params = parse_paren_params ps in
      let head =
        qq_chain (qq_sym name
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
       | _ -> qq_chain [qq_sym "if"; cond; then_b])
  | ("let" | "let*") when next_t = TLParen ->
      advance ps; advance ps;
      skip_nl ps;
      let rec binds acc =
        if (cur ps).t = TRParen then (advance ps; List.rev acc)
        else begin
          let name =
            match (peek ps ~nl:true).t with
            | TName s -> advance ps; s
            | t -> parse_error ps ("binding name must be a symbol, got "
                                   ^ string_of_btok t)
          in
          if (cur ps).t = TColon then
            parse_error ps "type annotations are not representable inside quasiquote";
          (match (peek ps ~nl:true).t with
           | TName "=" -> advance ps
           | t -> parse_error ps ("expected '=' in binding, got " ^ string_of_btok t));
          skip_nl ps;
          let v = parse_qq ps in
          match (peek ps ~nl:true).t with
          | TComma -> advance ps; skip_nl ps; binds (v :: qq_sym name :: acc)
          | TRParen -> advance ps; List.rev (v :: qq_sym name :: acc)
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

(* ---- Extension dispatch (M7 S3: flipped) ----

   `.pp` and `.ppb` read with the brace reader (`.pp` is now the default
   surface; `.ppb` remains a permanent alias — tests/054's fixtures use it).
   `.ppl` ("the AST form") reads with the sexpr reader — sexpr is demoted
   from "the syntax" to "the AST", still fully supported forever (it is the
   macro layer: `quote`/`defmacro` still traffic in sexpr data). Any other
   extension (REPL "<repl>"/"<?>" labels, `-e` input, synthetic glue source
   tags like "<stdlib:list.pp>") falls through to the sexpr reader,
   preserving every non-file caller's existing behavior byte-for-byte.
   [path] chooses the reader; [source] is the location label (when
   omitted, both readers' "<?>" default applies, preserving e.g.
   load-module's existing label behavior). *)

let file_uses_braces (path : string) : bool =
  Filename.check_suffix path ".pp" || Filename.check_suffix path ".ppb"

let read_dispatch ?(source : string option) ~(path : string) (input : string)
    : expr list =
  match source with
  | Some s ->
      if file_uses_braces path then read_string ~source:s input
      else Reader.read_string ~source:s input
  | None ->
      if file_uses_braces path then read_string input
      else Reader.read_string input
