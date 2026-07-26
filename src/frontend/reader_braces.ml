open Pp_kernel
(* pp brace reader — the brace surface syntax (SPEC Appendix B), parsing to the
   IDENTICAL `Core_model.expr` the s-expression reader produces for the equivalent
   program: same AST, same `ELocated` placement (§B.4), same shared desugars
   (src/frontend/desugar.ml), hence the same content keys. The grammar implemented here
   is exactly the one Appendix B specifies — the 7-level precedence table,
   the whitespace-sensitive infix rule (`a - b` subtracts, `a-b` is one
   identifier), `#` comments, `;`/newline statement separators with
   syntactic-incompleteness continuation, expression-position `{}` always a
   map, blocks only after the closed set of block-taking heads, and lowering
   rows L1–L61.

   Location placement mirrors reader.ml's sites exactly:
   - every top-level statement: ELocated (range-of-first-token, form)
   - `def`/`fn`/`node f(..)`: the range of the token AFTER the head keyword
     locates the body / return annotation / per-parameter checks
     (Desugar.assemble_fn_body)
   - `let x = e` / `node x { .. }`: EDefValue (x, ELocated (loc, rhs))
   - `assert`: the shared desugar renders the condition in s-expression
     notation, and runtime diagnostics carry the source range.

   Diagnostics carry structured ranges; string formatting is deferred to the
   shared error renderer. *)

open Core_model
open Source_error

type state = { source : string; mutable try_counter : int }

let create ?(source = "<?>") () = { source; try_counter = 0 }

(* ---- Tokens ---- *)

(* An f-string is lexed into ordered segments: literal text and interpolation
   holes. A hole carries its RAW source text, re-lexed and parsed by the
   reader (in whichever context the f-string appears — normal or quasiquote) so
   a hole is an arbitrary expression, not a restricted sub-grammar. *)
type fseg = FLit of string | FHole of string

type btok =
  | TLParen | TRParen
  | TLBracket | TRBracket
  | TLBrace | TRBrace
  | TComma | TSemi | TNewline
  | TString of string
  | TFString of fseg list    (* f"…{expr}…" — interpolated string *)
  | TInt of int
  | TFloat of float
  | TName of string          (* identifiers AND operator spellings (+ - |> ->) *)
  | TKeyword of string
  | TColon                   (* annotation separator *)
  | TEOF

let string_of_btok = function
  | TLParen -> "(" | TRParen -> ")"
  | TLBracket -> "[" | TRBracket -> "]"
  | TLBrace -> "{" | TRBrace -> "}"
  | TComma -> "," | TSemi -> ";" | TNewline -> "newline"
  | TString s -> Printf.sprintf "\"%s\"" (String.escaped s)
  | TFString _ -> "f-string"
  | TInt n -> string_of_int n
  | TFloat f -> string_of_float f
  | TName s -> s
  | TKeyword k -> ":" ^ k
  | TColon -> ":"
  | TEOF -> "<eof>"

(* [glued] = no whitespace/comment between this token's first character and
   the previous token's last character — the carrier of Appendix B's
   whitespace rule (infix operators require surrounding whitespace). *)
type tok = { t : btok; tline : int; trange : Source_range.t; glued : bool }

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
  let column = ref 1 in
  let toks = ref [] in
  let last_end = ref (-1) in   (* char index just past the previous token *)
  let token_column = ref 1 in
  let lex_error l msg =
    reader ~location:(Source_range.point ~source:file ~offset:!pos ~line:l
                       ~column:!column) msg in
  (* A token that scanned off the end of the source — the lexer's out-of-input
     signal, distinct from a genuine bad-character error. See
     Source_error.Reader_incomplete. *)
  let lex_incomplete l msg =
    incomplete ~location:(Source_range.point ~source:file ~offset:!pos ~line:l
                           ~column:!column) msg in
  let peek () = if !pos < len then Some input.[!pos] else None in
  let peek_at k = if !pos + k < len then Some input.[!pos + k] else None in
  let advance () =
    if !pos < len then begin
      let c = input.[!pos] in
      incr pos;
      if c = '\n' then begin incr line; column := 1 end
      else incr column
    end
  in
  let add_at start start_line t =
    let start_pos = Source_range.position ~offset:start ~line:start_line
        ~column:!token_column in
    let end_pos = Source_range.position ~offset:!pos ~line:!line
        ~column:!column in
    let trange = Source_range.make ~source:file ~start_pos ~end_pos in
    toks := { t; tline = start_line; trange; glued = (start = !last_end) } :: !toks;
    last_end := !pos
  in
  (* String body: same escapes as the sexpr reader (backslash n/t/backslash/
     quote; any other backslashed char is itself); literal newlines allowed. *)
  let read_string_body start_line =
    advance ();  (* opening quote *)
    let buf = Buffer.create 16 in
    let rec loop () =
      match peek () with
      | None -> lex_incomplete start_line "unterminated string"
      | Some '"' -> advance (); Buffer.contents buf
      | Some '\\' ->
          advance ();
          (match peek () with
           | Some 'n' -> advance (); Buffer.add_char buf '\n'; loop ()
           | Some 't' -> advance (); Buffer.add_char buf '\t'; loop ()
           | Some '\\' -> advance (); Buffer.add_char buf '\\'; loop ()
           | Some '"' -> advance (); Buffer.add_char buf '"'; loop ()
           | Some c -> advance (); Buffer.add_char buf c; loop ()
           | None -> lex_incomplete start_line "unterminated escape")
      | Some c ->
          advance ();
          Buffer.add_char buf c;
          loop ()
    in
    loop ()
  in
  (* f-string body: the f-prefixed quote. Scans literal text and {expr}
     holes into [fseg] segments. Doubled braces are literal braces; a hole runs
     until its MATCHING close brace (nested braces balanced, and string literals
     inside a hole copied verbatim so their braces/quotes do not confuse the
     balance). The hole raw source is re-parsed later by the reader in context.
     Same escape set as ordinary strings. Assumes f and the opening quote are
     current. *)
  let read_fstring start start_line =
    advance ();  (* 'f' *)
    advance ();  (* opening quote *)
    let segs = ref [] in
    let lit = Buffer.create 16 in
    let flush_lit () =
      if Buffer.length lit > 0 then begin
        segs := FLit (Buffer.contents lit) :: !segs; Buffer.clear lit
      end
    in
    let rec loop () =
      match peek () with
      | None -> lex_incomplete start_line "unterminated f-string"
      | Some '"' -> advance (); flush_lit ()
      | Some '\\' ->
          advance ();
          (match peek () with
           | Some 'n' -> advance (); Buffer.add_char lit '\n'; loop ()
           | Some 't' -> advance (); Buffer.add_char lit '\t'; loop ()
           | Some '\\' -> advance (); Buffer.add_char lit '\\'; loop ()
           | Some '"' -> advance (); Buffer.add_char lit '"'; loop ()
           | Some c -> advance (); Buffer.add_char lit c; loop ()
           | None -> lex_incomplete start_line "unterminated escape in f-string")
      | Some '{' when peek_at 1 = Some '{' ->
          advance (); advance (); Buffer.add_char lit '{'; loop ()
      | Some '}' when peek_at 1 = Some '}' ->
          advance (); advance (); Buffer.add_char lit '}'; loop ()
      | Some '}' ->
          lex_error start_line
            "unmatched '}' in f-string (use '}}' for a literal brace)"
      | Some '{' ->
          advance ();  (* consume the opening '{' *)
          flush_lit ();
          let hbuf = Buffer.create 16 in
          let rec hole depth =
            match peek () with
            | None -> lex_incomplete start_line "unterminated interpolation in f-string"
            | Some '}' when depth = 0 -> advance ()
            | Some '}' -> Buffer.add_char hbuf '}'; advance (); hole (depth - 1)
            | Some '{' -> Buffer.add_char hbuf '{'; advance (); hole (depth + 1)
            | Some '"' ->
                (* copy a nested string literal verbatim *)
                Buffer.add_char hbuf '"'; advance ();
                let rec str () =
                  match peek () with
                  | None -> lex_incomplete start_line
                              "unterminated string inside f-string interpolation"
                  | Some '\\' ->
                      Buffer.add_char hbuf '\\'; advance ();
                      (match peek () with
                       | Some c -> Buffer.add_char hbuf c; advance (); str ()
                       | None -> lex_incomplete start_line "unterminated escape")
                  | Some '"' -> Buffer.add_char hbuf '"'; advance ()
                  | Some c -> Buffer.add_char hbuf c; advance (); str ()
                in
                str (); hole depth
            | Some c ->
                Buffer.add_char hbuf c; advance (); hole depth
          in
          hole 0;
          let src = Buffer.contents hbuf in
          if String.trim src = "" then
            lex_error start_line "empty interpolation {} in f-string";
          segs := FHole src :: !segs;
          loop ()
      | Some c ->
          advance (); Buffer.add_char lit c; loop ()
    in
    loop ();
    add_at start start_line (TFString (List.rev !segs))
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
    token_column := !column;
    match peek () with
    | None -> add_at start start_line TEOF
    | Some (' ' | '\t' | '\r') -> advance (); run ()
    | Some '\n' -> advance (); add_at start start_line TNewline; run ()
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
        (* Glued to a preceding name or ')': annotation colon (`x: ty`).
           At token start (not glued): ':'+namechar is a keyword.
           (The fused cell-literal token `file:"P"` is removed — the `$`
           family is the one observation surface.) *)
        let glued_prev =
          start = !last_end
          && (match prev_tok () with
              | Some { t = (TName _ | TRParen); _ } -> true
              | _ -> false)
        in
        if glued_prev then begin
          advance ();
          add_at start start_line TColon
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
    | Some 'f' when peek_at 1 = Some '"' ->
        (* `f"…"` — the f-prefix is a lone `f` glued to the quote. A longer
           name like `foo"…"` still lexes as TName "foo" then TString. *)
        read_fstring start start_line; run ()
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

(* A "...x" spread prefix on a name token (list/map/call spread sugar). *)
let is_spread_prefix (s : string) : bool =
  String.length s >= 3 && String.sub s 0 3 = "..."

type ps = {
  toks : tok array;
  mutable pos : int;
  file : string;
  state : state;
}

let eof_tok = {
  t = TEOF;
  tline = 1;
  trange = Source_range.point ~source:"<?>" ~offset:0 ~line:1 ~column:1;
  glued = false;
}

let cur ps =
  if ps.pos < Array.length ps.toks then ps.toks.(ps.pos) else eof_tok

let advance ps = ps.pos <- ps.pos + 1

(* A parse failure is "incomplete" (the REPL should read more) iff the next
   significant token is end-of-input — the honest definition of running out of
   input, decided structurally rather than by message wording. Everything else
   is a genuine error on a token that is present. next_sig scans without
   mutating (unlike [peek ~nl], which consumes newlines via skip_nl). *)
let parse_error ps msg =
  let location = (cur ps).trange in
  let rec next_sig i =
    if i >= Array.length ps.toks then eof_tok
    else match ps.toks.(i).t with TNewline -> next_sig (i + 1) | _ -> ps.toks.(i)
  in
  if (next_sig ps.pos).t = TEOF then
    incomplete ~location msg
  else reader ~location msg

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

(* One precedence-climbing spine, two contexts. The normal reader and the
   `quasiquote{}` reader parse the SAME 7-level operator grammar (pipe/or/and/
   cmp/add/mul, then call/index postfix); they differ only in (i) what each
   binary/short-circuit/postfix combination *builds* — normal makes AST nodes,
   qq makes quoted list-building data — and (ii) newline significance (normal
   threads its caller's `c.nl`; qq peeks infix transparently but its postfix
   must NOT swallow a next-line `(`/`[`). Both are captured as
   fields here, so `climb_*` below exists once and a form added to the spine
   exists in both contexts by construction — a CI rule checking every normal
   parse-head has a quasiquote counterpart becomes
   a backstop rather than the mechanism. *)
(* Bracket/argument spread element (used by list literals and by
   call-argument lists). Defined here so [spine] below can reference it. *)
type bracket_elem = BElem of expr | BSpread of expr

type spine = {
  s_infix_nl   : bool;                          (* nl for infix-operator peeks *)
  s_postfix_nl : bool;                          (* nl for the `(`/`[` postfix peek *)
  s_leaf       : ps -> expr;                    (* primary parser (below postfix) *)
  s_bin        : string -> expr -> expr -> expr;(* cmp/add/mul combiner *)
  s_or         : expr -> expr -> expr;          (* short-circuit `or` *)
  s_and        : expr -> expr -> expr;          (* short-circuit `and` *)
  s_pipe       : (ps -> expr -> expr -> expr) option;  (* None ⇒ `|>` illegal here *)
  s_argv       : ps -> bracket_elem list;       (* `(a, …)` argument list, spread-aware *)
  s_index      : ps -> expr;                    (* the `[…]` index expression *)
  s_int_index  : expr -> bool;                  (* is the index a literal int? (vector-get) *)
  s_call       : expr -> bracket_elem list -> expr;  (* build `E(args…)`, lowering spread through `apply` *)
  s_get        : string -> expr -> expr -> expr;(* build `E[idx]` via [accessor] *)
}

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
  | TInt _ | TFloat _ | TString _ | TKeyword _ | TName _
  | TLParen | TLBracket -> true
  | _ -> false

let expect ps ~nl (t : btok) (what : string) =
  let k = peek ps ~nl in
  if k.t = t then advance ps
  else parse_error ps (Printf.sprintf "expected %s, got %s" what (string_of_btok k.t))

(* Interpret an observation-head lowering template (Surface_tables.tmpl) into
   real AST nodes for the normal reader. The quasiquote reader has its own
   interpreter (interp_head_qq) walking the SAME template into quoted
   list-building data, so both stay in lockstep. [args] are the user-supplied
   argument expressions, already arity-checked. *)
let rec interp_head_normal (args : expr list) (t : Surface_tables.tmpl) : expr =
  match t with
  | Surface_tables.Prim s -> ESymbol s
  | Surface_tables.Arg i -> List.nth args i
  | Surface_tables.App (fn :: rest) ->
      EApply (interp_head_normal args fn, List.map (interp_head_normal args) rest)
  | Surface_tables.App [] -> assert false
  | Surface_tables.If (c, th, el) ->
      EIf (interp_head_normal args c,
           interp_head_normal args th,
           interp_head_normal args el)
  | Surface_tables.Perform (eff, ts) ->
      EPerform (eff, List.map (interp_head_normal args) ts)
  | Surface_tables.Config (k, d) ->
      EConfig (interp_head_normal args k,
               Option.map (interp_head_normal args) d)

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

(* Map-literal entry: a spread `...m` or a `k -> v` pair *)
type map_entry = MSpread of expr | MPair of expr * expr
let fresh_try_var ps =
  ps.state.try_counter <- ps.state.try_counter + 1;
  "__try_" ^ string_of_int ps.state.try_counter

(* A parsed handler name: the `with-handler(name = fn, …)` name slot
   accepts a symbol or a keyword, in BOTH the normal and quasiquote readers.
   [parse_handler_pairs] parses the shared pair syntax once and returns these
   raw names; each reader maps them to its own representation (normal keeps the
   string; quasiquote builds `'sym` vs `'(quote :kw)` data). *)
type hname = HName of string | HKeyword of string


(* Call-spread helpers. [group_call_segments] collapses a bracket-element
   list into ordered segments: each maximal run of plain args becomes one
   `Run, each spread its own `Spread — the shape both spines render into an
   `apply(f, seg…)` call (segments are concatenated by the `apply` primitive). *)
let has_spread_elem = List.exists (function BSpread _ -> true | _ -> false)

let group_call_segments (elems : bracket_elem list)
    : [ `Run of expr list | `Spread of expr ] list =
  let flush cur out = if cur = [] then out else `Run (List.rev cur) :: out in
  let rec go cur out = function
    | [] -> List.rev (flush cur out)
    | BElem e :: rest -> go (e :: cur) out rest
    | BSpread s :: rest -> go [] (`Spread s :: flush cur out) rest
  in
  go [] [] elems

(* A match pattern's grammar is the same in both readers; only what it builds
   differs — the normal reader a real [Core_model.pattern], the quasiquote reader the
   quoted DATA (`_`/`(lit v)`/`(var "n")`/`(list (pats…) rest)`/`(tagged "t"
   pats…)`) that value_to_pattern reads back into the identical pattern. So the
   grammar is written once, parameterized by an ['a pattern_builder] and
   instantiated at ['a = Core_model.pattern] (normal) and ['a = expr] (qq). This is
   the one place the two contexts return DIFFERENT types, so — unlike the
   [spine] and [try_builder] records — the builder must be parametric.
   [pb_reject_unquote] carries the one grammar difference: qq forbids
   `unquote(...)` in pattern position (patterns are always literal there), where
   the normal reader accepts `unquote` as an ordinary variable name. *)
type 'a pattern_builder = {
  mk_pwild : 'a;
  mk_plit : value -> 'a;
  mk_pvar : string -> 'a;
  mk_plist : 'a list -> 'a option -> 'a;    (* elements, optional ...rest *)
  mk_ptagged : string -> 'a list -> 'a;     (* (:tag pats…) *)
  pb_reject_unquote : bool;
}

let normal_pattern_builder : Core_model.pattern pattern_builder = {
  mk_pwild = Core_model.PWildcard;
  mk_plit = (fun v -> Core_model.PLiteral v);
  mk_pvar = (fun n -> Core_model.PVariable n);
  mk_plist = (fun pats rest -> Core_model.PList (pats, rest));
  mk_ptagged = (fun tag pats -> Core_model.PTagged (tag, pats));
  pb_reject_unquote = false;
}

let rec parse_pattern_generic ps (pb : 'a pattern_builder) : 'a =
  let k = cur ps in
  match k.t with
  | TName "_" -> advance ps; pb.mk_pwild
  | TName "true" -> advance ps; pb.mk_plit (VBool true)
  | TName "false" -> advance ps; pb.mk_plit (VBool false)
  | TName "nil" -> advance ps; pb.mk_plit VNil
  | TName "unquote" when pb.pb_reject_unquote ->
      parse_error ps
        "patterns are always literal inside quasiquote { ... }: unquote(...) \
         is not supported in match-pattern position"
  | TName n -> advance ps; pb.mk_pvar n  (* any name is a variable pattern *)
  | TInt i -> advance ps; pb.mk_plit (VInt i)
  | TFloat f -> advance ps; pb.mk_plit (VFloat f)
  | TString s -> advance ps; pb.mk_plit (VString s)
  | TKeyword kw -> advance ps; pb.mk_plit (VKeyword kw)
  | TLBracket ->
      (* List pattern: [p1, p2, ...rest] *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; pb.mk_plist [] None)
      else begin
        let rec loop_pats acc =
          let k = cur ps in
          match k.t with
          | TName s when is_spread_prefix s ->
              (* Spread must be the last element; bind the remainder. *)
              advance ps;
              let rest_name = String.sub s 3 (String.length s - 3) in
              if rest_name = "" then
                parse_error ps "spread pattern '...' must be followed by a name or '_'";
              let rest_pat = if rest_name = "_" then pb.mk_pwild else pb.mk_pvar rest_name in
              skip_nl ps;
              expect ps ~nl:true TRBracket "']' after spread pattern";
              (List.rev acc, Some rest_pat)
          | _ ->
              let p = parse_pattern_generic ps pb in
              skip_nl ps;
              (match (cur ps).t with
               | TComma -> advance ps; skip_nl ps; loop_pats (p :: acc)
               | TRBracket -> advance ps; (List.rev (p :: acc), None)
               | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
        in
        let pats, rest = loop_pats [] in
        pb.mk_plist pats rest
      end
  | TLParen ->
      (* Tagged pattern (:tag pats…) or a parenthesized grouping *)
      advance ps;
      skip_nl ps;
      (match (cur ps).t with
       | TKeyword tag ->
           advance ps;
           let rec loop_pats acc =
             if (cur ps).t = TRParen then (advance ps; List.rev acc)
             else begin
               let p = parse_pattern_generic ps pb in
               loop_pats (p :: acc)
             end
           in
           pb.mk_ptagged tag (loop_pats [])
       | _ ->
           let p = parse_pattern_generic ps pb in
           expect ps ~nl:true TRParen "')'";
           p)
  | _ ->
      parse_error ps ("expected pattern, got " ^ string_of_btok k.t)

(* Match arms — the same grammar in both readers (skip separators; an arm is
   `pattern [if guard] => body`; stop at `}`), differing only in what a pattern
   and a guard/body parse to, and how an arm is assembled. Written once here and
   parameterized; each caller wraps the returned ['arm list] its own way (the
   normal reader hands the list straight to EMatch; the quasiquote reader
   qq_chains it into `(match scrutinee (arm…))` data). [parse_guard] and
   [parse_body] are separate because the normal reader parses a guard in
   `cond` context and a body without it. [what] tails the unterminated-block
   message. *)
let parse_match_arms_generic ps ~(parse_pat : ps -> 'p)
    ~(parse_guard : ps -> expr) ~(parse_body : ps -> expr)
    ~(mk_arm : 'p -> expr option -> expr -> 'arm) ~(what : string) : 'arm list =
  let rec skip_seps () =
    match (cur ps).t with
    | TNewline | TSemi -> advance ps; skip_seps ()
    | _ -> ()
  in
  let rec loop acc =
    skip_seps ();
    if (cur ps).t = TRBrace then (advance ps; List.rev acc)
    else if (cur ps).t = TEOF then parse_error ps ("unterminated match block" ^ what)
    else begin
      let pat = parse_pat ps in
      let guard =
        match (peek ps ~nl:true).t with
        | TName "if" -> advance ps; skip_nl ps; Some (parse_guard ps)
        | _ -> None
      in
      (match peek_infix ps ~nl:true ["=>"] with
       | Some _ -> advance ps
       | None -> parse_error ps "match arm must be `pattern [if guard] => body`");
      skip_nl ps;
      let body = parse_body ps in
      loop (mk_arm pat guard body :: acc)
    end
  in
  loop []

(* One dispatch over the head-word set, two readers. [parse_head_ctx] matches a
   head keyword once; a [head_builder] supplies how each reader parses the
   sub-parts and builds the form — the normal reader real AST (often desugared:
   EFn via type checks, `and`/`or`/`assert` expanded), the quasiquote reader
   the quoted list DATA that reconstructs the same form. Because the match lives
   in one place, a head form cannot exist in one reader and not the other — a
   property that no longer needs a separate coverage check. Some forms are one
   reader only (unquote/
   splice are quasiquote-only; fenced/with/vec/defmacro are normal-only); the
   builder's method for the other side raises the "not representable" error, so
   the single dispatch still enumerates the whole set. Builder methods that build
   a block take [ps] because the normal reader validates block definitions and
   wraps the body, work the quasiquote reader (which splices raw items) does not.
   Several quasiquote arms (config/load/island/assert) deliberately parse a
   coarse argument list rather than the normal reader's structured grammar, so a
   macro can splice `unquote(...)` where the normal reader requires a literal;
   for those the whole per-reader parse lives in the builder method. *)
type head_builder = {
  hb_expr : ps -> expr;                 (* a free-context sub-expression *)
  hb_args : ps -> expr list;            (* an argument list, '(' already consumed *)
  hb_block_items : ps -> expr list;     (* the statements of a `{ }` block *)
  hb_handler_pairs : ps -> (hname * expr) list;
  mk_one : string -> expr -> expr;                       (* force/delay/import *)
  mk_with : ps -> string -> expr -> expr list -> expr;   (* with-caps/with-config *)
  mk_with_handler : ps -> (hname * expr) list -> expr list -> expr;
  mk_perform : string -> expr list -> expr;
  mk_block_form : ps -> string -> expr list -> expr;     (* do/module *)
  mk_node_expr : ps -> expr list -> expr;                (* node { } *)
  mk_andor : string -> expr list -> expr;
  mk_fn : ps -> expr;                                    (* fn(params) { } *)
  mk_def : ps -> expr;                                   (* def name(params) { } *)
  mk_let : ps -> string -> expr;                         (* let/let* (binds) { } *)
  mk_quote : ps -> expr;                                 (* quote { } *)
  mk_reconcile : ps -> expr;                             (* reconcile { } *)
  (* config/load/load-module/island/assert: the normal reader parses each's
     structured grammar; the quasiquote reader a coarse argument list (so a
     macro can splice unquote where the normal reader wants a literal). *)
  mk_arglist_form : ps -> string -> expr;
  mk_if : ps -> expr;
  mk_try : ps -> expr;
  mk_match : ps -> expr;
  (* quote/quasiquote/unquote/splice in call position: the normal reader a
     plain application; the quasiquote reader escapes unquote/splice and quotes
     the head of a call-position quote/quasiquote. *)
  mk_call_special : ps -> string -> expr;
}

let rec parse_expr ps (c : ctx) : expr =
  climb_pipe (normal_spine c) ps

(* The normal reader's spine ops. Infix and postfix peeks both use the caller's
   `c.nl` (statement/body positions pass nl=false, so a trailing newline ends
   the expression); combinations build AST nodes; `|>` is a reader-level rewrite
   (identifier ⇒ 1-arg call; call form ⇒ prepend). *)
and normal_spine (c : ctx) : spine = {
  s_infix_nl   = c.nl;
  s_postfix_nl = c.nl;
  s_leaf       = (fun ps -> parse_primary ps c);
  s_bin        = (fun op l r -> EApply (ESymbol op, [l; r]));
  s_or         = (fun l r -> EIf (l, ELiteral (VBool true), r));
  s_and        = (fun l r -> EIf (l, r, ELiteral (VBool false)));
  s_pipe       = Some (fun ps left rhs ->
    match rhs with
    | ESymbol _ -> EApply (rhs, [left])
    | EApply (f, args) -> EApply (f, left :: args)
    | _ -> parse_error ps
             "the right-hand side of |> must be an identifier or a call form");
  s_argv       = (fun ps -> parse_call_args ps ~elem:(fun ps -> parse_expr ps free_ctx));
  s_index      = (fun ps -> parse_expr ps free_ctx);
  s_int_index  = (function ELiteral (VInt _) -> true | _ -> false);
  s_call       = (fun e elems ->
    (* A spread anywhere in the argument list lowers `f(a, ...rest, b)` to
       `apply(f, list(a), rest, list(b))` — consecutive plain args grouped into
       one `list(...)` segment, each spread its own segment; the `apply`
       primitive concatenates the segments and calls f. Spread-free calls keep
       the ordinary `EApply(f, args)` shape (hash-preserving). *)
    if has_spread_elem elems then
      EApply (ESymbol "apply",
              e :: List.map (function
                     | `Run es -> EApply (ESymbol "list", es)
                     | `Spread s -> s)
                     (group_call_segments elems))
    else EApply (e, List.map (function BElem x -> x | BSpread x -> x) elems));
  s_get        = (fun acc l r -> EApply (ESymbol acc, [l; r]));
}

(* level 7: |> — loosest; left-associative; pure reader-level rewriting *)
and climb_pipe sp ps =
  let left = ref (climb_or sp ps) in
  let rec loop () =
    match peek_infix ps ~nl:sp.s_infix_nl ["|>"] with
    | Some _ ->
        (match sp.s_pipe with
         | None -> parse_error ps "|> is not representable inside quasiquote { ... }"
         | Some mk ->
             advance ps;
             skip_nl ps;
             let rhs = climb_or sp ps in
             left := mk ps !left rhs;
             loop ())
    | None -> ()
  in
  loop ();
  !left

(* level 6: or — right-associative (reproduces the variadic desugar) *)
and climb_or sp ps =
  let left = climb_and sp ps in
  match peek_infix ps ~nl:sp.s_infix_nl ["or"] with
  | Some _ ->
      advance ps; skip_nl ps;
      let right = climb_or sp ps in
      sp.s_or left right
  | None -> left

(* level 5: and — right-associative *)
and climb_and sp ps =
  let left = climb_cmp sp ps in
  match peek_infix ps ~nl:sp.s_infix_nl ["and"] with
  | Some _ ->
      advance ps; skip_nl ps;
      let right = climb_and sp ps in
      sp.s_and left right
  | None -> left

(* level 4: comparisons — non-associative; chaining is a parse error. (Folding
   the two spines closed a drift: the qq copy lacked this check, so a chained
   `a < b < c` inside quasiquote{} died with a confusing downstream "expected
   ',' or ')'" instead of this message. Both now reject it the same way.) *)
and climb_cmp sp ps =
  let left = climb_add sp ps in
  match peek_infix ps ~nl:sp.s_infix_nl infix_cmp with
  | Some op ->
      advance ps; skip_nl ps;
      let right = climb_add sp ps in
      (match peek_infix ps ~nl:sp.s_infix_nl infix_cmp with
       | Some _ ->
           parse_error ps
             "comparison operators do not chain (use the call form, e.g. <(a, b, c))"
       | None -> ());
      sp.s_bin op left right
  | None -> left

(* level 3: + - — left-associative, strictly binary *)
and climb_add sp ps =
  let left = ref (climb_mul sp ps) in
  let rec loop () =
    match peek_infix ps ~nl:sp.s_infix_nl infix_add with
    | Some op ->
        advance ps; skip_nl ps;
        let right = climb_mul sp ps in
        left := sp.s_bin op !left right;
        loop ()
    | None -> ()
  in
  loop ();
  !left

(* level 2: * / mod *)
and climb_mul sp ps =
  let left = ref (climb_postfix sp ps) in
  let rec loop () =
    match peek_infix ps ~nl:sp.s_infix_nl infix_mul with
    | Some op ->
        advance ps; skip_nl ps;
        let right = climb_postfix sp ps in
        left := sp.s_bin op !left right;
        loop ()
    | None -> ()
  in
  loop ();
  !left

(* level 1: call postfix E(a, ...) and index postfix E[k] — left-associative.
   The index accessor is chosen by [s_int_index]: a syntactically literal int
   index is `vector-get`, anything else `hash-map-get` (L10). *)
and climb_postfix sp ps =
  let e = ref (sp.s_leaf ps) in
  let rec loop () =
    match (peek ps ~nl:sp.s_postfix_nl).t with
    | TLParen ->
        advance ps;
        let args = sp.s_argv ps in
        e := sp.s_call !e args;
        loop ()
    | TLBracket ->
        advance ps;
        skip_nl ps;
        let idx = sp.s_index ps in
        expect ps ~nl:true TRBracket "']'";
        let accessor = if sp.s_int_index idx then "vector-get" else "hash-map-get" in
        e := sp.s_get accessor !e idx;
        loop ()
    | _ -> ()
  in
  loop ();
  !e

(* Thin wrapper kept for the few external callers (parameter/return-type
   annotations) that parse at exactly the postfix level. *)
and parse_postfix ps c = climb_postfix (normal_spine c) ps

(* comma-separated expressions up to ')' (consumed); [elem] parses one element
   (a normal expression or a qq datum), shared by both readers' argument lists. *)
and parse_arglist ps ~(elem : ps -> expr) : expr list =
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let e = elem ps in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop (e :: acc)
      | TRParen -> advance ps; List.rev (e :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    loop []
  end

and parse_args ps : expr list = parse_arglist ps ~elem:(fun ps -> parse_expr ps free_ctx)

(* Re-lex and parse an f-string hole's raw source into one expression, using
   the context's own [parse] (parse_expr for normal, parse_qq inside a
   quasiquote — so a hole may itself contain `unquote(...)`). Must consume the
   whole hole. *)
and fstring_hole_expr ~(state : state) ~(file : string) (src : string)
    ~(parse : ps -> expr) : expr =
  let toks = lex ~file src in
  let hps = { toks = Array.of_list toks; pos = 0; file; state } in
  let e = parse hps in
  skip_nl hps;
  (match (cur hps).t with
   | TEOF -> ()
   | t -> parse_error hps (Printf.sprintf
            "unexpected %s after an f-string interpolation expression"
            (string_of_btok t)));
  e

(* Lower f-string segments: each non-empty literal → a string literal,
   each hole → `->string(<hole>)`; join with `string-append`. A single part
   (one literal `f"abc"`, or one hole `f"{x}"`) is emitted bare (no wrapper),
   so `f"abc"` is byte-for-byte the same AST as `"abc"`. The [lit]/[hole]/
   [append] builders differ per context (AST vs quoted qq data). *)
and lower_fstring ~(lit : string -> expr) ~(hole : string -> expr)
    ~(append : expr list -> expr) (segs : fseg list) : expr =
  let parts = List.filter_map (function
    | FLit "" -> None
    | FLit s -> Some (lit s)
    | FHole src -> Some (hole src)) segs in
  match parts with
  | [] -> lit ""
  | [one] -> one
  | many -> append many

(* Spread-aware call-argument list: like [parse_arglist] but a `...x`
   element is captured as a [BSpread] rather than parsed as a bogus symbol.
   `...rest` (glued) takes its target from the token suffix; a bare `...`
   parses the following expression, mirroring [parse_bracket_elems]. *)
and parse_call_args ps ~(elem : ps -> expr) : bracket_elem list =
  skip_nl ps;
  if (cur ps).t = TRParen then (advance ps; [])
  else begin
    let rec loop acc =
      let item =
        match (cur ps).t with
        | TName s when is_spread_prefix s ->
            advance ps;
            let target =
              if String.length s > 3 then ESymbol (String.sub s 3 (String.length s - 3))
              else elem ps
            in
            BSpread target
        | _ -> BElem (elem ps)
      in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; loop (item :: acc)
      | TRParen -> advance ps; List.rev (item :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    loop []
  end

(* Shared `with-handler(name = value, …)` pair parser. The pair syntax —
   a symbol/keyword name, `=`, a value, comma-separated, up to `)` — is
   identical in both readers; only the value parser and the built shape differ,
   so each caller passes its [parse_value] and maps the returned raw pairs. One
   parser means the two contexts cannot drift: previously the quasiquote copy
   silently accepted a trailing comma while the normal copy rejected it (like
   every other comma list in the grammar, e.g. [parse_args]); folding them here
   makes both reject it. *)
and parse_handler_pairs ps ~(parse_value : unit -> expr) : (hname * expr) list =
  if (peek ps ~nl:true).t = TRParen then (advance ps; [])
  else begin
    let rec pairs acc =
      let name =
        match (peek ps ~nl:true).t with
        | TName s -> advance ps; HName s
        | TKeyword k -> advance ps; HKeyword k
        | t -> parse_error ps ("handler name must be a symbol or keyword, got "
                               ^ string_of_btok t)
      in
      (match (peek ps ~nl:true).t with
       | TName "=" -> advance ps
       | t -> parse_error ps ("expected '=' after handler name, got "
                              ^ string_of_btok t));
      skip_nl ps;
      let v = parse_value () in
      match (peek ps ~nl:true).t with
      | TComma -> advance ps; skip_nl ps; pairs ((name, v) :: acc)
      | TRParen -> advance ps; List.rev ((name, v) :: acc)
      | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t)
    in
    pairs []
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
  | TFString segs ->
      advance ps;
      lower_fstring segs
        ~lit:(fun s -> ELiteral (VString s))
        ~hole:(fun src -> EApply (ESymbol "->string",
                 [fstring_hole_expr ~state:ps.state ~file:ps.file src
                    ~parse:(fun hps -> parse_expr hps free_ctx)]))
        ~append:(fun parts -> EApply (ESymbol "string-append", parts))
  | TKeyword kw -> advance ps; ELiteral (VKeyword kw)
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
        let elems = parse_bracket_elems_normal ps in
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
      (* $KIND(args...) — observation sigils, table-driven (Surface_tables).
         Every head parses its arguments as an ordinary expression list,
         so a computed path such as $file(build <> "/out") works; per-head
         string-literal restrictions no longer exist. An unknown $foo is left
         as the bare symbol (postfix application still applies to it). *)
      let kind = String.sub n 1 (String.length n - 1) in
      advance ps;
      (match Surface_tables.find_head kind with
       | None ->
           parse_error ps
             (Printf.sprintf "unknown observation head $%s; %s"
                kind (Surface_tables.known_heads_message ()))
       | Some spec ->
           expect ps ~nl:true TLParen (Printf.sprintf "'(' after $%s" kind);
           let args = parse_args ps in
           let n = List.length args in
           (match Surface_tables.check_arity spec n with
            | Ok () -> interp_head_normal args (spec.Surface_tables.tmpl n)
            | Error msg -> parse_error ps msg))
  | TName n -> parse_head ps c n

(* { k1 -> v1, k2 -> v2, ... } -> (hash-map k1 v1 k2 v2 ...)
   { ...m, k -> v, ... } -> spread/update: map-merge / map-insert.
   The old `{ base | k -> v }` update form is removed — `{ ...base, k -> v }`
   is the one spelling; multiple spreads merge, rightmost wins.
   cur = '{' *)
and parse_map_literal ps : expr =
  advance ps;
  skip_nl ps;
  if (cur ps).t = TRBrace then (advance ps; EApply (ESymbol "hash-map", []))
  else
    build_map_literal
      (parse_map_entries ps
         ~parse_elem:(fun () -> parse_expr ps free_ctx)
         ~mk_spread_sym:(fun s -> ESymbol s))

(* Collect map entries (`...spread` or `k -> v` pairs) until the closing '}'.
   Shared by the normal and quasiquote readers: [parse_elem] parses a key,
   value, or bare-`...` spread target in the caller's context (AST vs quoted
   data); [mk_spread_sym] builds the target of a glued `...name` spread. *)
and parse_map_entries ps ~parse_elem ~mk_spread_sym : map_entry list =
  let rec loop acc =
    match (cur ps).t with
    | TName s when is_spread_prefix s ->
        advance ps;
        let target =
          if String.length s > 3 then mk_spread_sym (String.sub s 3 (String.length s - 3))
          else parse_elem ()
        in
        finish (MSpread target :: acc)
    | _ ->
        let key = parse_elem () in
        (match peek_infix ps ~nl:true ["->"] with
         | Some _ -> advance ps
         | None ->
             parse_error ps
               ("expected '->' between map key and value, got "
                ^ string_of_btok (peek ps ~nl:true).t));
        skip_nl ps;
        let v = parse_elem () in
        finish (MPair (key, v) :: acc)
  and finish acc =
    match (peek ps ~nl:true).t with
    | TComma -> advance ps; skip_nl ps; loop acc
    | TRBrace -> advance ps; List.rev acc
    | t -> parse_error ps ("expected ',' or '}', got " ^ string_of_btok t)
  in
  loop []

(* Lower map entries. A spread-free literal keeps its `(hash-map k v …)`
   shape verbatim (hash-preserving — every existing map literal is untouched).
   With any spread present, fold left, merging spreads (rightmost wins) and
   inserting pairs. When the FIRST entry is a spread, it is the initial
   accumulator (not an empty map merged into) — so `{ ...m, k -> v }` lowers to
   `map-insert(m, k, v)`, exactly what the removed `{ m | k -> v }` update form
   produced, keeping the stdlib migration hash-preserving. Identical in both
   readers: the builders are evaluated to build the value in both contexts. *)
and build_map_literal (entries : map_entry list) : expr =
  let has_spread = List.exists (function MSpread _ -> true | _ -> false) entries in
  if not has_spread then
    EApply (ESymbol "hash-map",
            List.concat_map
              (function MPair (k, v) -> [k; v] | MSpread _ -> []) entries)
  else
    let init, rest =
      match entries with
      | MSpread e :: rest -> (e, rest)
      | _ -> (EApply (ESymbol "hash-map", []), entries)
    in
    List.fold_left
      (fun acc entry -> match entry with
         | MSpread e -> EApply (ESymbol "map-merge", [acc; e])
         | MPair (k, v) -> EApply (ESymbol "map-insert", [acc; k; v]))
      init rest

(* Parse the `handlers: { :name -> fn, ... }` clause map into (name, fn)
   pairs for EWithHandler. Keys must be keyword literals (`:name`) or bare
   names; spread is not accepted. cur is the opening '{'. *)
and parse_handler_map ps : (string * expr) list =
  advance ps;  (* consume '{' *)
  skip_nl ps;
  if (cur ps).t = TRBrace then (advance ps; [])
  else
    let entries =
      parse_map_entries ps
        ~parse_elem:(fun () -> parse_expr ps free_ctx)
        ~mk_spread_sym:(fun s -> ESymbol s)
    in
    List.map
      (function
        | MSpread _ ->
            parse_error ps "spread is not allowed in a handlers map"
        | MPair (ELiteral (VKeyword name), v) -> (name, v)
        | MPair (ESymbol name, v) -> (name, v)
        | MPair _ ->
            parse_error ps
              "handler map keys must be keyword literals (:name)")
      entries

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

(* block rule ⟦stmts⟧, sharing reader.ml's exact desugar and validation;
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

and parse_head_ctx ps (hb : head_builder) (n : string) : expr option =
  let next_t = (peek2 ps).t in
  match n with
  | ("force" | "delay" | "import") when next_t = TLParen ->
      advance ps; advance ps; skip_nl ps;
      let e = hb.hb_expr ps in
      expect ps ~nl:true TRParen "')'";
      Some (hb.mk_one n e)
  | ("with-caps" | "with-config") when next_t = TLParen ->
      advance ps; advance ps; skip_nl ps;
      let e = hb.hb_expr ps in
      expect ps ~nl:true TRParen "')'";
      Some (hb.mk_with ps n e (hb.hb_block_items ps))
  | "with-handler" when next_t = TLParen ->
      advance ps; advance ps; skip_nl ps;
      let pairs = hb.hb_handler_pairs ps in
      Some (hb.mk_with_handler ps pairs (hb.hb_block_items ps))
  | "perform" when (match next_t with TName _ -> true | _ -> false) ->
      advance ps;
      let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
      advance ps;
      if (cur ps).t <> TLParen then
        parse_error ps "perform requires an argument list: perform name(args)";
      advance ps;
      Some (hb.mk_perform name (hb.hb_args ps))
  | ("do" | "module") when next_t = TLBrace ->
      advance ps;
      Some (hb.mk_block_form ps n (hb.hb_block_items ps))
  | "node" when next_t = TLBrace ->
      advance ps;
      Some (hb.mk_node_expr ps (hb.hb_block_items ps))
  | ("and" | "or") when next_t = TLParen ->
      advance ps; advance ps;
      Some (hb.mk_andor n (hb.hb_args ps))
  | "fn" when next_t = TLParen -> Some (hb.mk_fn ps)
  | "def" when (match next_t with TName _ -> true | _ -> false) ->
      Some (hb.mk_def ps)
  | ("let" | "let*") when next_t = TLParen ->
      advance ps; Some (hb.mk_let ps n)
  | "quote" when next_t = TLBrace -> advance ps; Some (hb.mk_quote ps)
  | "reconcile" when next_t = TLBrace -> advance ps; Some (hb.mk_reconcile ps)
  | ("config" | "load" | "load-module" | "island" | "assert") when next_t = TLParen ->
      advance ps; advance ps;
      Some (hb.mk_arglist_form ps n)
  | "if" when starts_expr next_t -> Some (hb.mk_if ps)
  | "try" when next_t = TLBrace -> Some (hb.mk_try ps)
  | "match" when starts_expr next_t -> Some (hb.mk_match ps)
  | "quasiquote" when next_t = TLBrace ->
      advance ps;
      Some (match parse_qq_block_items ps with
            | [f] -> EApply (ESymbol "quasiquote", [f])
            | _ -> parse_error ps "quasiquote { ... } must contain exactly one form")
  | ("quote" | "quasiquote" | "unquote" | "splice") when next_t = TLParen ->
      Some (hb.mk_call_special ps n)
  | _ -> None

and normal_head_builder : head_builder = {
  hb_expr = (fun ps -> parse_expr ps free_ctx);
  hb_args = (fun ps -> parse_args ps);
  hb_block_items = (fun ps -> skip_nl ps; parse_block_stmts ps);
  hb_handler_pairs =
    (fun ps -> parse_handler_pairs ps ~parse_value:(fun () -> parse_expr ps free_ctx));
  mk_one = (fun n e -> match n with
    | "force" -> EForce e | "delay" -> EDelay e | "import" -> EImport e
    | _ -> assert false);
  mk_with = (fun ps n e items -> match n with
    | "with-caps" -> EWithCaps (e, block_body_of ps items)
    | "with-config" -> EWithConfig (e, block_body_of ps items)
    | _ -> assert false);
  mk_with_handler = (fun ps pairs items ->
    let handlers =
      List.map (function (HName s, h) | (HKeyword s, h) -> (s, h)) pairs in
    EWithHandler (handlers, block_body_of ps items));
  mk_perform = (fun name args -> EPerform (name, args));
  mk_block_form = (fun ps n items -> match n with
    | "do" -> EDo (check_defs ps items)
    | "module" -> EModule (check_defs ps items)
    | _ -> assert false);
  mk_node_expr = (fun ps items -> ENode (block_body_of ps items));
  mk_andor = (fun n args ->
    if n = "and" then Desugar.desugar_and args else Desugar.desugar_or args);
  mk_fn = (fun ps ->
    advance ps;
    let location = (cur ps).trange in
    let locate e = ELocated (location, e) in
    let params = parse_paren_params ps in
    let ret_ty = parse_ret_ty ps in
    let body = parse_block_body ps in
    let names, body' = Desugar.assemble_fn_body locate params ret_ty body in
    EFn (names, body'));
  mk_def = (fun ps ->
    advance ps;
    let location = (cur ps).trange in
    let locate e = ELocated (location, e) in
    let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
    advance ps;
    if (cur ps).t <> TLParen then
      parse_error ps "def requires a parameter list: def name(params) { ... }";
    let params = parse_paren_params ps in
    let ret_ty = parse_ret_ty ps in
    let body = parse_block_body ps in
    let names, body' = Desugar.assemble_fn_body locate params ret_ty body in
    EDef (name, names, body'));
  mk_let = (fun ps n ->
    let binds = parse_binding_group ps ~allow_ty:(n = "let") in
    let body = parse_block_body ps in
    if n = "let*" then ELetStar (binds, body) else ELet (binds, body));
  mk_quote = (fun ps ->
    match parse_block_stmts ps with
    | [f] -> EQuote f
    | _ -> parse_error ps "quote { ... } must contain exactly one form");
  mk_reconcile = (fun ps -> parse_map_literal ps);
  mk_arglist_form = (fun ps n -> match n with
    | "config" ->
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
    | "assert" ->
        skip_nl ps;
        let cond = parse_expr ps free_ctx in
        (match (peek ps ~nl:true).t with
         | TComma ->
             advance ps; skip_nl ps;
             let m = parse_expr ps free_ctx in
             expect ps ~nl:true TRParen "')'";
             Desugar.desugar_assert cond (Some m)
         | TRParen ->
             advance ps;
             Desugar.desugar_assert cond None
         | t -> parse_error ps ("expected ',' or ')', got " ^ string_of_btok t))
    | "load" ->
        (match (peek ps ~nl:true).t with
         | TString p -> advance ps; expect ps ~nl:true TRParen "')'"; ELoad p
         | _ -> parse_error ps "load expects a string path")
    | "load-module" ->
        (match (peek ps ~nl:true).t with
         | TString p -> advance ps; expect ps ~nl:true TRParen "')'"; ELoadModule p
         | _ -> parse_error ps "load-module expects a string path")
    | "island" ->
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
    | _ -> assert false);
  mk_if = (fun ps -> parse_if ps);
  mk_try = (fun ps ->
    advance ps; skip_nl ps;
    let stmts = parse_try_stmts ps in
    Desugar.lower_try ~fresh_var:(fun () -> fresh_try_var ps)
      Desugar.normal_try_builder stmts);
  mk_match = (fun ps ->
    advance ps;
    let scrutinee = parse_expr ps { nl = false; cond = true } in
    skip_nl ps;
    expect ps ~nl:false TLBrace "'{'";
    let arms = parse_match_arms ps in
    EMatch (scrutinee, arms));
  mk_call_special = (fun ps n ->
    advance ps; advance ps;
    let args = parse_args ps in
    EApply (ESymbol n, args));
}

and qq_head_builder : head_builder = {
  hb_expr = (fun ps -> parse_qq ps);
  hb_args = (fun ps -> parse_qq_args ps);
  hb_block_items = (fun ps -> parse_qq_block_items ps);
  hb_handler_pairs =
    (fun ps -> parse_handler_pairs ps ~parse_value:(fun () -> parse_qq ps));
  mk_one = (fun n e -> qq_chain [qq_sym n; e]);
  mk_with = (fun _ps n e items -> qq_chain (qq_sym n :: e :: items));
  mk_with_handler = (fun _ps pairs items ->
    let flat = List.concat_map (fun (name, h) ->
      let name_e = match name with
        | HName s -> qq_sym s
        | HKeyword k -> EQuote (ELiteral (VKeyword k)) in
      [name_e; h]) pairs in
    qq_chain (qq_sym "with-handler" :: EApply (ESymbol "vector", flat) :: items));
  mk_perform = (fun name args -> qq_chain (qq_sym "perform" :: qq_sym name :: args));
  mk_block_form = (fun _ps n items -> qq_chain (qq_sym n :: items));
  mk_node_expr = (fun _ps items ->
    let body = match items with
      | [one] -> one | items -> qq_chain (qq_sym "do" :: items) in
    qq_chain [qq_sym "node"; body]);
  mk_andor = (fun n args -> qq_chain (qq_sym n :: args));
  mk_fn = (fun ps ->
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
    qq_chain (qq_sym "fn" :: param_data :: body));
  mk_def = (fun ps ->
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
    qq_chain (qq_sym "def" :: head :: body));
  mk_let = (fun ps n ->
    advance ps;  (* '(' *)
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
    qq_chain (qq_sym n :: EApply (ESymbol "vector", flat) :: body));
  mk_quote = (fun ps ->
    match parse_qq_block_items ps with
    | [f] -> EQuote f
    | _ -> parse_error ps "quote { ... } must contain exactly one form");
  mk_reconcile = (fun ps -> parse_qq_primary ps);
  mk_arglist_form = (fun ps n -> qq_chain (qq_sym n :: parse_qq_args ps));
  mk_if = (fun ps ->
    parse_if_ctx ps
      ~parse_cond:parse_qq_cond
      ~parse_block:parse_qq_block_one
      ~mk_if:(fun cond then_b else_e ->
        match else_e with
        | Some e -> qq_chain [qq_sym "if"; cond; then_b; e]
        | None -> qq_chain [qq_sym "if"; cond; then_b]));
  mk_try = (fun ps ->
    advance ps; skip_nl ps;
    let stmts =
      parse_try_stmts_ctx ps ~parse_stmt:parse_qq ~what:" in quasiquote" in
    Desugar.lower_try ~fresh_var:(fun () -> fresh_try_var ps)
      qq_try_builder stmts);
  mk_match = (fun ps ->
    advance ps;
    let scrutinee = parse_qq ps in
    skip_nl ps;
    expect ps ~nl:false TLBrace "'{'";
    let arms = parse_qq_match_arms ps in
    qq_chain [qq_sym "match"; scrutinee; arms]);
  mk_call_special = (fun ps n -> match n with
    | "unquote" ->
        advance ps; advance ps; skip_nl ps;
        let e = parse_expr ps free_ctx in
        expect ps ~nl:true TRParen "')'";
        EApply (ESymbol "list", [EQuote (ESymbol "unquote"); e])
    | "splice" ->
        advance ps; advance ps; skip_nl ps;
        let e = parse_expr ps free_ctx in
        expect ps ~nl:true TRParen "')'";
        EApply (ESymbol "list", [EQuote (ESymbol "unquote-splicing"); e])
    | _ -> advance ps; EQuote (ESymbol n));
}

and parse_head ps c (n : string) : expr =
  match parse_head_ctx ps normal_head_builder n with
  | Some e -> e
  | None ->
  (* Forms unique to the normal reader (node definitions, `with`, `let x = E`,
     the normal-only `fenced`/`defmacro`/`vec`, `@` attributes) plus the
     bare-symbol fallback. Every form shared with the quasiquote reader lives in
     parse_head_ctx above. *)
  let next_t = (peek2 ps).t in
  match n with
  | "node" when (match next_t with TName _ -> true | _ -> false) ->
      advance ps;
      let location = (cur ps).trange in
      let locate e = ELocated (location, e) in
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
                 (* Dotted grant descriptors are table-driven sugar
                    (Surface_tables.grant_sugar); `needs` itself stays
                    value-open — any other expression passes through to
                    cap-compose unchanged. *)
                 let lower_item = function
                   | EApply (ESymbol d, [e]) as orig ->
                       (match Surface_tables.find_grant_sugar d with
                        | Some g -> needs_restrict e g.Surface_tables.restrict_mode
                        | None -> orig)
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
          (* Clause keyword set is table-driven (Surface_tables.with_clauses):
             the "caps"/"config"/"handler" strings live only in that table. *)
          let clause_of =
            match (cur ps).t with
            | TName kw -> Surface_tables.find_with_clause kw
            | _ -> None
          in
          match clause_of with
          | Some ({ wrapper = Surface_tables.WCaps; _ } as cl) when (peek2 ps).t = TColon ->
              advance ps; advance ps; skip_nl ps;
              let cap = parse_expr ps { nl = false; cond = false } in
              if caps_opt <> None then
                parse_error ps ("duplicate " ^ cl.Surface_tables.clause ^ ": clause in with block");
              parse_clauses (Some cap) config_opt handlers
          | Some ({ wrapper = Surface_tables.WConfig; _ } as cl) when (peek2 ps).t = TColon ->
              advance ps; advance ps; skip_nl ps;
              let m = parse_expr ps { nl = false; cond = false } in
              if config_opt <> None then
                parse_error ps ("duplicate " ^ cl.Surface_tables.clause ^ ": clause in with block");
              parse_clauses caps_opt (Some m) handlers
          | Some { wrapper = Surface_tables.WHandlers; _ } when (peek2 ps).t = TColon ->
              (* `handlers: { :name -> fn, ... }` — a map-valued clause
                 replacing the old two-token `handler NAME: fn` key. Its
                 `:name -> fn` pairs are extracted into the handler install. *)
              advance ps; advance ps; skip_nl ps;  (* consume 'handlers' ':' *)
              if (cur ps).t <> TLBrace then
                parse_error ps
                  "handlers: takes a map literal { :name -> fn, ... }";
              let pairs = parse_handler_map ps in
              parse_clauses caps_opt config_opt (List.rev_append pairs handlers)
          | _ ->
              parse_error ps
                (Surface_tables.with_clauses_message ()
                 ^ ", got " ^ string_of_btok (cur ps).t)
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
      (* `@` attributes are removed from the language. `@cache` was a second
         spelling of `node`; an `@needs` that parses without narrowing authority
         is a lie in a capability language (DESIGN §6). `node` is the one, always
         structural, spelling of node-ness. *)
      parse_error ps
        (Printf.sprintf
           "`%s` attributes are not part of the language; use `node` for caching and `needs` for authority"
           n)
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
           let name = (match (cur ps).t with TName s -> s | _ -> assert false) in
           advance ps;
           if (cur ps).t = TColon then
             parse_error ps
               ("a `let " ^ name ^ " = ...` binding takes no type annotation \
                 (use let (" ^ name ^ ": ty = ...) { ... })");
           advance ps;  (* '=' *)
           skip_nl ps;
           let location = (cur ps).trange in
           let rhs = parse_expr ps c in
           EDefValue (name, ELocated (location, rhs))
       | TLParen ->
           (* L23/L24: let (x [: ty] = e, ...) { body... } *)
           advance ps;
           let binds = parse_binding_group ps ~allow_ty:true in
           let body = parse_block_body ps in
           ELet (binds, body)
       | _ -> advance ps; ESymbol "let")
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
  | "vec" when next_t = TLBracket ->
      (* vec[e1, e2, ...] -> (vector e1 e2 ...); spread: vec[a, ...rest] *)
      advance ps;  (* consume "vec" *)
      advance ps;  (* consume "[" *)
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; EApply (ESymbol "vector", []))
      else begin
        let elems = parse_bracket_elems_normal ps in
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


(* Bracket/call-spread elements, shared by both readers: [elem] parses each
   element and each bare `...` spread target in the caller's context (AST vs
   quoted data), [mk_spread_sym] builds the target of a glued `...name` spread —
   exactly the split parse_map_entries uses. *)
and parse_bracket_elems ps ~(elem : ps -> expr) ~(mk_spread_sym : string -> expr)
    : bracket_elem list =
  let rec loop acc =
    match (cur ps).t with
    | TName s when is_spread_prefix s ->
        advance ps;
        let target =
          if String.length s > 3 then
            (* suffix is part of the token: ...rest *)
            mk_spread_sym (String.sub s 3 (String.length s - 3))
          else
            (* bare ..., parse next expression *)
            elem ps
        in
        (match (peek ps ~nl:true).t with
         | TComma -> advance ps; skip_nl ps; loop (BSpread target :: acc)
         | TRBracket -> advance ps; List.rev (BSpread target :: acc)
         | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
    | _ ->
        let e = elem ps in
        (match (peek ps ~nl:true).t with
         | TComma -> advance ps; skip_nl ps; loop (BElem e :: acc)
         | TRBracket -> advance ps; List.rev (BElem e :: acc)
         | t -> parse_error ps ("expected ',' or ']', got " ^ string_of_btok t))
  in
  loop []

and parse_bracket_elems_normal ps : bracket_elem list =
  parse_bracket_elems ps
    ~elem:(fun ps -> parse_expr ps free_ctx) ~mk_spread_sym:(fun s -> ESymbol s)

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


(* Parse the statements inside a `try { }` block, one grammar for both readers:
   [parse_stmt] parses each bind rhs and bare statement (the normal reader in a
   brace-free statement context, the quasiquote reader through parse_qq so
   unquote/splice work there), and [what] tails the unterminated-block message.
   Each item is a `Desugar.TryBind (name, rhs)` for a `name <- expr` bind or a
   `Desugar.TryExpr e` for a normal statement. *)
and parse_try_stmts_ctx ps ~(parse_stmt : ps -> expr) ~(what : string)
    : Desugar.try_stmt list =
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
    else if k.t = TEOF then parse_error ps ("unterminated try block" ^ what)
    else begin
      match k.t with
      | TName name when not k.glued && not (peek2 ps).glued && (peek2 ps).t = TName "<-" ->
          advance ps;  (* consume name *)
          advance ps;  (* consume <- *)
          skip_nl ps;
          let rhs = parse_stmt ps in
          loop (Desugar.TryBind (name, rhs) :: acc)
      | _ ->
          (* Postfix `?` is removed. `<-` is the one propagation spelling.
             A plain `let x = expr` here is an ordinary sequential binding
             (EDefValue) scoping to the rest of the try block. *)
          let e = parse_stmt ps in
          if (cur ps).t = TName "?" && (cur ps).glued then
            parse_error ps
              "postfix `?` is not part of the language; use `name <- expr` to unwrap";
          loop (Desugar.TryExpr e :: acc)
    end
  in
  loop []

and parse_try_stmts ps : Desugar.try_stmt list =
  parse_try_stmts_ctx ps
    ~parse_stmt:(fun ps -> parse_expr ps { nl = false; cond = false })
    ~what:""

(* Parse match arms inside { } — the shared arm grammar with the normal
   pattern/expr parsers. The guard is parsed brace-free (cond) like an `if`
   condition; `=>` is not a spine infix, so the guard/body parse stops at it. *)
and parse_match_arms ps : (Core_model.pattern * expr option * expr) list =
  parse_match_arms_generic ps
    ~parse_pat:parse_pattern
    ~parse_guard:(fun ps -> parse_expr ps { nl = false; cond = true })
    ~parse_body:(fun ps -> parse_expr ps { nl = false; cond = false })
    ~mk_arm:(fun pat guard body -> (pat, guard, body))
    ~what:""

(* Parse a single pattern (real Core_model.pattern): the shared grammar with the
   normal builder. *)
and parse_pattern ps : Core_model.pattern =
  parse_pattern_generic ps normal_pattern_builder
(* if C { T... } [else if C2 { ... }]* [else { E... }] — L37–L39.
   cur = the `if` name token; the condition is parsed brace-free (Go-style).
   One grammar, two contexts: [parse_cond] and [parse_block] supply how each
   reader parses a condition and a block, and [mk_if] builds the result from
   (cond, then, optional-else) — the normal reader a real EIf (a missing else
   defaults to nil), the quasiquote reader the quoted `(if …)` list data
   (2-element when there is no else). A newline may legitimately separate `}`
   from `else`: peek past newlines but only consume them when `else` actually
   follows, so an otherwise-trailing newline still terminates the statement. *)
and parse_if_ctx ps ~(parse_cond : ps -> expr) ~(parse_block : ps -> expr)
    ~(mk_if : expr -> expr -> expr option -> expr) : expr =
  advance ps;  (* 'if' *)
  let cond = parse_cond ps in
  let then_b = parse_block ps in
  let else_e =
    let save = ps.pos in
    skip_nl ps;
    match (cur ps).t with
    | TName "else" ->
        advance ps;
        (match (cur ps).t with
         | TName "if" -> Some (parse_if_ctx ps ~parse_cond ~parse_block ~mk_if)
         | TLBrace -> Some (parse_block ps)
         | t -> parse_error ps ("expected 'if' or '{' after else, got "
                                ^ string_of_btok t))
    | _ -> ps.pos <- save; None
  in
  mk_if cond then_b else_e

and parse_if ps : expr =
  parse_if_ctx ps
    ~parse_cond:(fun ps -> parse_expr ps { nl = false; cond = true })
    ~parse_block:parse_block_body
    ~mk_if:(fun cond then_b else_e ->
      EIf (cond, then_b, Option.value else_e ~default:(ELiteral VNil)))

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
   the equivalent code builds, NOT a vector), maps as hash-map builds.
   unquote(E)/splice(E) escape to a normally-parsed E. Desugars
   (and/or/assert/...) never apply here: quoted data is data.

   Coverage: atoms, names (reserved words included), calls, the infix operator
   levels, grouping, list literals, maps, quote/quasiquote nesting, fn/def/if/
   let/let*/do/perform/with-caps/with-config/with-handler/module/import/force/
   delay/config/load/load-module/island/assert/node and cell literals,
   try { ... } (parse_qq_try_stmts/qq_lower_try_block, the same
   nested let/if data lower_try_block builds as real nodes), match E { pat
   => body; ... } (parse_qq_match_arms/parse_qq_pattern, the same arm/
   pattern data Quotation.quote_to_value's EMatch case builds — Quotation.value_to_expr gained
   a matching "match" case + value_to_pattern, since EMatch is a first-
   class AST node with no prior Quotation.quote_to_value inverse), postfix m[k]
   index (parse_qq_postfix's TLBracket arm, same vector-get/hash-map-get
   accessor choice as parse_postfix), and list-literal spread
   `[a, ...rest]` (parse_qq_primary's TLBracket arm, same cons(a, rest)
   shape build_spread_list builds).

   `unquote(E)` is legal in a
   let/let* BINDING NAME and a def's FUNCTION NAME (parse_qq_name_slot) —
   the two "computed name" shapes real macro templates need: a gensym'd
   hygienic temporary (`let (unquote(g) = unquote(a)) { if unquote(g) ... }`)
   and a macro-generated def name (`def unquote(name)(x) { ... }`).
   splice(e) works in any list/argument/block position (parse_qq_*
   routes every element through parse_qq, which dispatches splice at
   parse_qq_head). Match
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
   three is to build the application via `list`/`cons` calls
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
   list-literal SPREAD case: `[a, ...rest]`'s data must be the SAME
   `cons(a, rest)` shape the ordinary bracket-literal spread builds
   (build_spread_list), not always nil-terminated. *)
and qq_chain_tail (items : expr list) (tail : expr) : expr =
  List.fold_right (fun e acc -> EApply (ESymbol "cons", [e; acc])) items tail

and qq_sym (s : string) : expr = EQuote (ESymbol s)

(* Quasiquote counterpart of interp_head_normal: the SAME Surface_tables.tmpl,
   walked into quoted list-building data instead of AST nodes. An application
   `App [f; a; b]` becomes the cons-chain `(f a b)` (qq_chain), and `If` becomes
   `(if c t e)` — exactly the data shapes the normal lowering's EApply/EIf
   reconstruct after macro expansion, so a `$file(...)` written inside a
   quasiquote template builds a value `=` to the one the bare form lowers to. *)
and interp_head_qq (args : expr list) (t : Surface_tables.tmpl) : expr =
  match t with
  | Surface_tables.Prim s -> qq_sym s
  | Surface_tables.Arg i -> List.nth args i
  | Surface_tables.App ts -> qq_chain (List.map (interp_head_qq args) ts)
  | Surface_tables.If (c, th, el) ->
      qq_chain [qq_sym "if"; interp_head_qq args c;
                interp_head_qq args th; interp_head_qq args el]
  | Surface_tables.Perform (eff, ts) ->
      qq_chain (qq_sym "perform" :: qq_sym eff :: List.map (interp_head_qq args) ts)
  | Surface_tables.Config (k, d) ->
      (* Mirror Quotation.quote_to_value (EConfig …): `(config KEY DEFAULT-or-nil)` — a
         3-element form so Quotation.value_to_expr reconstructs an EConfig after expansion. *)
      let default = match d with Some d -> interp_head_qq args d | None -> qq_nil in
      qq_chain [qq_sym "config"; interp_head_qq args k; default]

and parse_qq ps : expr =
  climb_pipe (qq_spine ()) ps

(* The quasiquote reader's spine ops (see [spine] / [climb_*]). Combinations
   build quoted list-building data (`qq_chain`/`qq_sym`) instead of AST nodes;
   `|>` is illegal (not representable as data); infix peeks are transparent to
   newlines (nl=true) but the postfix peek is NOT (nl=false): a
   bare `(`/`[` opening the NEXT line must never be swallowed as this primary's
   postfix call/index — a qq match-arm body or try-statement rhs sits in
   exactly such a position (`v + 1` on one line, `[:err, e] => 0` on the next
   must parse as two things). The int-index test matches `EQuote (ELiteral
   (VInt _))` — the only qq shape a literal int index parses to — so the
   vector-get/hash-map-get choice is the same decision the normal reader makes
   on its unwrapped index. *)
and qq_spine () : spine = {
  s_infix_nl   = true;
  s_postfix_nl = false;
  s_leaf       = parse_qq_primary;
  s_bin        = (fun op l r -> qq_chain [qq_sym op; l; r]);
  s_or         = (fun l r -> qq_chain [qq_sym "or"; l; r]);
  s_and        = (fun l r -> qq_chain [qq_sym "and"; l; r]);
  s_pipe       = None;
  s_argv       = (fun ps -> parse_call_args ps ~elem:parse_qq);
  s_index      = parse_qq;
  s_int_index  = (function EQuote (ELiteral (VInt _)) -> true | _ -> false);
  s_call       = (fun e elems ->
    (* In quasiquote: build the SAME `(apply f (list …) rest …)` data the
       normal reader lowers to, in quoted form — `apply`/`list` are ordinary
       symbols, so Quotation.value_to_expr reconstructs the identical EApply after macro
       expansion (parity is free, no special reflection case). *)
    if has_spread_elem elems then
      qq_chain (qq_sym "apply" :: e ::
                List.map (function
                  | `Run es -> qq_chain (qq_sym "list" :: es)
                  | `Spread s -> s)
                  (group_call_segments elems))
    else qq_chain (e :: List.map (function BElem x -> x | BSpread x -> x) elems));
  s_get        = (fun acc l r -> qq_chain [qq_sym acc; l; r]);
}

and parse_qq_args ps : expr list = parse_arglist ps ~elem:parse_qq

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
  | TFString segs ->
      advance ps;
      lower_fstring segs
        ~lit:(fun s -> EQuote (ELiteral (VString s)))
        ~hole:(fun src -> qq_chain [qq_sym "->string";
                 fstring_hole_expr ~state:ps.state ~file:ps.file src ~parse:parse_qq])
        ~append:(fun parts -> qq_chain (qq_sym "string-append" :: parts))
  | TKeyword kw -> advance ps; EQuote (ELiteral (VKeyword kw))
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
         (a cons-chain list, VNil-terminated), not a vector. Also
         handles surface spread `[a, ...rest]`: mirrors parse_bracket_elems /
         build_spread_list exactly, only routing every
         element (and the spread target) through parse_qq instead of
         parse_expr, so unquote/splice work in any position — including
         `...unquote(xs)` to splice a REAL runtime list value as the tail,
         the realistic use (a bare `...rest` quotes the symbol `rest`
         itself, same as any other unlifted qq atom). *)
      advance ps;
      skip_nl ps;
      if (cur ps).t = TRBracket then (advance ps; qq_nil)
      else begin
        let elems =
          parse_bracket_elems ps ~elem:parse_qq ~mk_spread_sym:qq_sym in
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
        let entries =
          parse_map_entries ps
            ~parse_elem:(fun () -> parse_qq ps)
            ~mk_spread_sym:(fun s -> qq_sym s)
        in
        (* Map SPREAD is a documented quasiquote exclusion (SPEC B.7).
           A quasiquote map is built eagerly (quasiquote_walk does not descend
           into a VMap), so a spread's `map-merge` would run before unquotes
           are substituted. Plain `{ k -> v }` literals parse unchanged. *)
        if List.exists (function MSpread _ -> true | _ -> false) entries then
          parse_error ps
            "map spread `{ ...m }` is not supported inside quasiquote{} \
             (SPEC B.7); build the map with map-merge/map-insert calls"
        else build_map_literal entries
      end
  | TName "true" -> advance ps; EQuote (ELiteral (VBool true))
  | TName "false" -> advance ps; EQuote (ELiteral (VBool false))
  | TName "nil" -> advance ps; EQuote (ELiteral VNil)
  | TName n -> parse_qq_head ps n

(* A "name slot" inside a qq_head shape (a let/let* binding
   name, or a def's function name) — ordinarily a bare identifier, quoted
   verbatim (qq_sym), OR `unquote(E)`, to
   the extent macros actually need it: the canonical gensym hygiene pattern
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
  match parse_head_ctx ps qq_head_builder n with
  | Some e -> e
  | None ->
  (* Forms unique to the quasiquote reader: defmacro/needs (not representable)
     and $KIND observation heads; plus the bare-symbol fallback. Every form
     shared with the normal reader lives in parse_head_ctx above. *)
  match n with
  | ("defmacro" | "needs") ->
      parse_error ps (n ^ " is not representable inside quasiquote { ... }")
  | _ when String.length n > 0 && n.[0] = '$'
           && (match Surface_tables.find_head (String.sub n 1 (String.length n - 1)) with
               | Some h -> h.Surface_tables.qq_legal | None -> false) ->
      (* $KIND(args) inside quasiquote, same table, same template as the
         normal reader, so a head added once exists in both by construction.
         args routed through parse_qq so unquote/splice work in argument
         position; the built value equals what the bare form lowers to. *)
      let kind = String.sub n 1 (String.length n - 1) in
      let spec = match Surface_tables.find_head kind with
        | Some h -> h | None -> assert false in
      advance ps;
      expect ps ~nl:true TLParen (Printf.sprintf "'(' after $%s" kind);
      let args = parse_qq_args ps in
      let cnt = List.length args in
      (match Surface_tables.check_arity spec cnt with
       | Ok () -> interp_head_qq args (spec.Surface_tables.tmpl cnt)
       | Error msg -> parse_error ps msg)
  | _ ->
      advance ps;
      EQuote (ESymbol n)

(* condition of `if` inside quasiquote: brace-free, one qq expression *)
and parse_qq_cond ps : expr =
  (* reuse the qq precedence chain; a top-level '{' simply stops it *)
  parse_qq ps

(* The quasiquote reader's try_builder: the SAME nested let/if shape
   Desugar.lower_try builds, as quoted DATA (qq_chain/qq_sym) instead of real
   ELet/EIf/EApply nodes, so Quotation.value_to_expr (or the runtime `quasiquote` builtin,
   for a non-macro use) reconstructs exactly what the direct `try { ... }` parse
   produces. A `let` binding becomes the `(let (vector name val) body)` data
   shape Core_model.binding_pairs reads back. Every bind rhs / bare statement is
   routed through parse_qq at the parse step (parse_try_stmts_ctx), so
   unquote/splice work in a try statement's expression position; bind NAMES stay
   bare identifiers (same convention as parse_qq_name_slot — no macro test needs
   a computed try-bind name). *)
and qq_try_builder : Desugar.try_builder = {
  Desugar.t_ok_kw = EQuote (ELiteral (VKeyword "ok"));
  t_sym = (fun s -> qq_sym s);
  t_app = (fun f args -> qq_chain (qq_sym f :: args));
  t_do  = (fun es -> qq_chain (qq_sym "do" :: es));
  t_let = (fun name v body ->
    qq_chain [qq_sym "let"; EApply (ESymbol "vector", [qq_sym name; v]); body]);
  t_if  = (fun c t e -> qq_chain [qq_sym "if"; c; t; e]);
}

(* The quasiquote reader's pattern builder: the shape quote_pattern produces
   (`_`/`(lit v)`/`(var "n")`/`(list (pats…) rest)`/`(tagged "t" pats…)`), so
   value_to_pattern reconstructs the identical Core_model.pattern after macro
   expansion. A function (not a value) because its fields apply the recursive
   qq_sym/qq_chain helpers eagerly. Patterns stay fully literal here
   (pb_reject_unquote = true): unquote(...) in pattern position is a worded parse
   error, not silently dropped. *)
and qq_pattern_builder () : expr pattern_builder = {
  mk_pwild = qq_sym "_";
  mk_plit = (fun v -> qq_chain [qq_sym "lit"; EQuote (ELiteral v)]);
  mk_pvar = (fun n -> qq_chain [qq_sym "var"; EQuote (ELiteral (VString n))]);
  mk_plist = (fun pats rest ->
    qq_chain [qq_sym "list"; qq_chain pats;
              (match rest with Some r -> r | None -> qq_nil)]);
  mk_ptagged = (fun tag pats ->
    qq_chain (qq_sym "tagged" :: EQuote (ELiteral (VString tag)) :: pats));
  pb_reject_unquote = true;
}

and parse_qq_pattern ps : expr =
  parse_pattern_generic ps (qq_pattern_builder ())

(* Match arms inside quasiquote — the shared arm grammar with the qq
   pattern/expr parsers, each arm a qq list `(pat body)` or `(pat guard body)`,
   exactly the shape Quotation.quote_to_value's EMatch case builds for `arms`, then
   qq_chained into the arm-list value. *)
and parse_qq_match_arms ps : expr =
  qq_chain (parse_match_arms_generic ps
    ~parse_pat:parse_qq_pattern
    ~parse_guard:parse_qq
    ~parse_body:parse_qq
    ~mk_arm:(fun pat guard body ->
      match guard with
      | None -> qq_chain [pat; body]
      | Some g -> qq_chain [pat; g; body])
    ~what:" in quasiquote")

(* ---- Public API ---- *)

(* Read brace-surface source text into top-level forms, each ELocated at the
   line of its first token — exactly Reader.read_string's wrapping. *)
let read state (input : string) : expr list =
  let toks = lex ~file:state.source input in
  let ps = {
    toks = Array.of_list toks; pos = 0; file = state.source; state
  } in
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
        (* Fresh temp-var numbering per top-level form, so a form's
           content hash depends only on the form (and its location), never on
           how many `try` blocks were parsed earlier in the process/file. *)
        state.try_counter <- 0;
        let start_range = (cur ps).trange in
        let e = parse_expr ps { nl = false; cond = false } in
        (match (cur ps).t with
         | TNewline | TSemi | TEOF -> ()
         | t ->
             parse_error ps
               ("expected newline or ';' between statements, got "
                ^ string_of_btok t));
        result := ELocated (start_range, e) :: !result;
        loop ()
  in
  loop ();
  List.rev !result

let read_string ?(source : string = "<?>") input =
  read (create ~source ()) input

(* ---- Extension dispatch ----

   `.pp` and `.ppb` read with the brace reader (`.pp` is the default
   surface; `.ppb` remains a permanent alias).
   `.ppl` ("the AST form") reads with the sexpr reader — sexpr is demoted
   from "the syntax" to "the AST", still fully supported forever (it is the
   macro layer: `quote`/`defmacro` still traffic in sexpr data). The reader's
   own "<?>" default label — reached ONLY by `pp -e` (repl.ml's
   execute_string, called with no ~source, i.e. no
   real file at all) — also reads braces. Synthetic glue source tags command_run.ml builds for itself
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

(* ---- REPL multi-line continuation ----

   Whether [input] is still an open form that needs more lines before it can be
   read — used by repl.ml's read_form to decide whether to keep accumulating
   under the "..> " prompt. It runs the SAME parse the REPL will use to evaluate
   the input and classifies the outcome by exception TYPE: Reader_incomplete
   means the reader ran out of input (a form still open — an unterminated
   string, a bracket/block awaiting its close, an infix/statement continuation),
   so read more; a plain Failure is a genuine syntax error on a token that is
   present, so hand it to the REPL's error path. Because the reader raises
   Reader_incomplete exactly where it hits end of input (parser: next
   significant token is EOF; lexer: an unterminated token), continuation no
   longer depends on error-message wording, and an error whose text merely
   contains "unterminated"/"<eof>" as data is never mistaken for an open form.
   Reusing the real reader — rather than a standalone bracket-counter — keeps
   this in step with the grammar's every "awaiting a block/paren/comma" shape. *)
let needs_more_input ?(source : string = "<repl>") (input : string) : bool =
  try ignore (read_string ~source input); false
  with
  | Reader_incomplete _ -> true
  | Error (Reader (Syntax _)) | Failure _ -> false
  | _ -> false
