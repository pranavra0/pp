(* pp sexpr printer — renders a `Types.expr` (as produced by EITHER reader,
   src/reader.ml or src/reader_braces.ml) as s-expression text that the
   sexpr reader (src/reader.ml) re-reads to the structurally IDENTICAL expr
   — same `ELocated` placement, hence the same LAW-20 hash. This is the
   other half of `pp fmt` (M7 S2; src/printer_braces.ml is the first half),
   built with the same location-preserving discipline: pad newlines so
   every construct's recorded (file, line) lands exactly, and raise
   [Unprintable] if a located line was already passed.

   Sexpr is easier to invert into than braces: it is *whitespace-
   insensitive* end to end — reader.ml's lexer treats '\n' exactly like any
   other blank (no statement-separator role at all; see its `next_delim`).
   That means a line-padding newline is syntactically legal at literally
   any point in the output (unlike printer_braces's `~brk`, which tracks
   positions where a break would prematurely end a statement) — so this
   printer's `require_line` never needs that flag, and application is
   fully n-ary/variadic (no infix spelling gymnastics: `(+ a b c)` is just
   an ordinary call, unlike the brace surface's strictly-binary `a + b`).

   Spelling decisions, each load-bearing for hash preservation:
   - every reader.ml special-form keyword (def/fn/if/let/let*/and/or/quote/
     force/delay/node/defnode/do/with-caps/perform/with-handler/module/
     import/load/load-module/island/with-config/config/assert) is recognized
     ONLY as the car of a literal list in reader.ml — a bare occurrence of
     the symbol (unapplied) reads back as an ordinary `ESymbol`, so (unlike
     printer_braces) no reserved-word wrapping is needed for symbols standing
     alone. Only an *application* headed by one of these symbols is
     unprintable (defensive: no AST either reader produces ever applies one
     as a function — Types.expr gives each its own dedicated constructor).
   - `defmacro` is deliberately NOT one of reader.ml's special forms
     (src/macro.ml's docstring); `(defmacro (name p...) body...)` is an
     perfectly ordinary application and needs no special-casing here.
   - quasiquote ASTs (built by either reader's qq-mode) print as their
     already-lowered form (cons chains, `(quote ...)`, and a plain
     `(quasiquote ...)` application) — "quasiquote" isn't itself one of
     reader.ml's dispatched keywords (only the backtick TOKEN is; the AST
     node is an ordinary `EApply (ESymbol "quasiquote", ...)`), so this
     needs no un-lowering either.
   - assert desugars print as the plain `if`/`error` form they already are.
   - reader-only sugar (pipeline, cells, `reconcile`, `needs` — all brace-
     surface-only to begin with) never reaches this printer as such: it is
     already lowered to core forms by the time an AST exists. *)

open Types

exception Unprintable of string

let unpr fmt = Printf.ksprintf (fun s -> raise (Unprintable s)) fmt

let is_digit c = c >= '0' && c <= '9'

(* reader.ml's is_symbol_char, verbatim (notably: ':' is a legal symbol
   character here — only a LEADING ':' switches the lexer into
   read_keyword; braces' is_name_char excludes ':' everywhere instead). *)
let is_symbol_char c =
  match c with
  | ' ' | '\t' | '\n' | '\r' | ',' -> false
  | '(' | ')' | '[' | ']' | '{' | '}' -> false
  | '<' -> false
  | '\'' | '`' | '"' | ';' | '#' | '~' -> false
  | _ -> true

(* reader.ml's parse_special_form dispatch table: symbols recognized ONLY
   as the car of a literal list. `defmacro`/`quasiquote`/`unquote`/`splice`
   are deliberately absent (see file header). *)
let special_form_heads = [
  "def"; "fn"; "if"; "let"; "let*"; "and"; "or"; "quote"; "force"; "delay";
  "node"; "defnode"; "do"; "with-caps"; "perform"; "with-handler"; "module";
  "import"; "load"; "load-module"; "island"; "with-config"; "config"; "assert";
]

let name_ok (s : string) : bool =
  s = "<" || s = "<="
  || (s <> ""
      && String.for_all is_symbol_char s
      && s.[0] <> ':'
      && not (is_digit s.[0])
      && not (String.length s >= 2 && s.[0] = '-'
              && (is_digit s.[1]
                  || (s.[1] = '.' && String.length s >= 3 && is_digit s.[2])))
      && s <> "true" && s <> "false" && s <> "nil")

(* ---- literals (same spellings/round-trip requirements as printer_braces —
   both lexers share the same number grammar and string escapes) ---- *)

let string_lit (s : string) : string =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter (fun c ->
    match c with
    | '\\' -> Buffer.add_string b "\\\\"
    | '"' -> Buffer.add_string b "\\\""
    | '\n' -> Buffer.add_string b "\\n"
    | '\t' -> Buffer.add_string b "\\t"
    | c -> Buffer.add_char b c) s;
  Buffer.add_char b '"';
  Buffer.contents b

let float_lit (f : float) : string =
  if f <> f || f = infinity || f = neg_infinity then
    unpr "float %h has no surface literal" f;
  let ensure_dot s =
    if String.contains s '.' then s
    else match String.index_opt s 'e' with
      | Some i -> String.sub s 0 i ^ "." ^ String.sub s i (String.length s - i)
      | None -> s ^ "."
  in
  let bits = Int64.bits_of_float f in
  let try_s s =
    match float_of_string_opt s with
    | Some g when Int64.bits_of_float g = bits -> Some s
    | _ -> None
  in
  match try_s (ensure_dot (string_of_float f)) with
  | Some s -> s
  | None ->
      (match try_s (ensure_dot (Printf.sprintf "%.17g" f)) with
       | Some s -> s
       | None -> unpr "float %h does not round-trip through its literal" f)

let literal (v : value) : string =
  match v with
  | VNil -> "nil"
  | VBool true -> "true"
  | VBool false -> "false"
  | VInt n -> string_of_int n
  | VFloat f -> float_lit f
  | VString s -> string_lit s
  | VKeyword k ->
      if k <> "" && String.for_all is_symbol_char k then ":" ^ k
      else unpr "keyword :%s has no sexpr spelling" k
  | v -> unpr "value %s is not a literal" (string_of_value v)

(* ---- emitter state ----

   No `~brk` tracking (see file header): a required line strictly greater
   than the current one is ALWAYS reachable by padding blank newlines,
   anywhere in sexpr text. *)

type st = {
  buf : Buffer.t;
  mutable line : int;
  src : string;
  strict : bool;
}

let emit st s = Buffer.add_string st.buf s
let newline st = Buffer.add_char st.buf '\n'; st.line <- st.line + 1

let require_line st (l : int) (what : string) =
  if not st.strict then ()
  else if l < st.line then
    unpr "cannot place %s at line %d: output is already at line %d" what l st.line
  else if l > st.line then
    while st.line < l do newline st done

let check_file st (f : string) =
  if st.strict && f <> st.src then
    unpr "located file %S does not match the printed source %S" f st.src

(* ---- fn/def/defnode body inversion (Desugar.assemble_fn_body, reversed) —
   identical shape-matching to printer_braces.ml's invert_fn_body: this
   logic reasons purely about the shared (surface-agnostic) desugared AST
   shape, not about concrete syntax, so it is duplicated verbatim rather
   than shared (matching this codebase's existing reader.ml/reader_braces.ml
   precedent of independent surface-specific files over Desugar.ml's shared
   reader-facing pieces). *)

type inverted = {
  i_loc : (string * int) option;
  i_annots : (string * expr) list;
  i_ret : expr option;
  i_body : expr;
}

let invert_fn_body (params : string list) (body' : expr) : inverted =
  let split_last l =
    match List.rev l with
    | last :: rev_init -> (List.rev rev_init, last)
    | [] -> unpr "empty desugared function body"
  in
  let tail_part e =
    match e with
    | ELocated (loc, ETyped (b, ty)) -> (loc, Some ty, b)
    | ELocated (loc, b) -> (loc, None, b)
    | _ -> unpr "function body is not in assemble_fn_body shape"
  in
  match body' with
  | EDo items when items <> [] ->
      let checks, last = split_last items in
      if checks = [] then unpr "function body EDo without parameter checks";
      let annots =
        List.map (function
          | ELocated (loc, ETyped (ESymbol p, ty)) -> (loc, p, ty)
          | _ -> unpr "function body is not in assemble_fn_body shape")
          checks
      in
      let loc, ret, body = tail_part last in
      List.iter (fun (l, _, _) ->
        if l <> loc then unpr "parameter checks carry inconsistent locations")
        annots;
      let annots = List.map (fun (_, p, ty) -> (p, ty)) annots in
      let rec verify ps ans =
        match ps, ans with
        | _, [] -> ()
        | p :: ps', (q, _) :: ans' when p = q -> verify ps' ans'
        | _ :: ps', ans -> verify ps' ans
        | [], _ :: _ -> unpr "parameter checks do not match the parameter list"
      in
      verify params annots;
      { i_loc = Some loc; i_annots = annots; i_ret = ret; i_body = body }
  | ELocated _ ->
      let loc, ret, body = tail_part body' in
      { i_loc = Some loc; i_annots = []; i_ret = ret; i_body = body }
  | b -> { i_loc = None; i_annots = []; i_ret = None; i_body = b }

let block_stmts_of (body : expr) : expr list =
  match body with
  | EDo l when List.length l >= 2 -> l
  | e -> [e]

(* ---- the printer ---- *)

let rec print_expr st (e : expr) : unit =
  match e with
  | ELocated ((f, l), inner) ->
      check_file st f;
      require_line st l "a located form";
      print_expr st inner
  | ELiteral v -> emit st (literal v)
  | ESymbol s ->
      if not (name_ok s) then unpr "symbol %s has no sexpr spelling" s
      else emit st s
  | EIf (c, t, e) -> print_if st c t e
  | ELet (binds, body) ->
      emit st "(let [";
      print_bindings st binds;
      emit st "]";
      print_body_stmts st (block_stmts_of body);
      emit st ")"
  | ELetStar (binds, body) ->
      emit st "(let* [";
      print_plain_bindings st binds;
      emit st "]";
      print_body_stmts st (block_stmts_of body);
      emit st ")"
  | EFn (params, body') ->
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) -> check_file st f; require_line st l "fn"
       | None -> ());
      emit st "(fn ";
      print_params st params inv.i_annots;
      print_ret st inv.i_ret;
      print_body_stmts st (block_stmts_of inv.i_body);
      emit st ")"
  | EDef (name, params, body') ->
      if not (name_ok name) then unpr "def name %s has no sexpr spelling" name;
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) -> check_file st f; require_line st l ("def " ^ name)
       | None -> ());
      emit st "(def ";
      print_name_params st name params inv.i_annots;
      print_ret st inv.i_ret;
      print_body_stmts st (block_stmts_of inv.i_body);
      emit st ")"
  | EDefNode (name, params, body') ->
      if not (name_ok name) then unpr "node name %s has no sexpr spelling" name;
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) -> check_file st f; require_line st l ("defnode " ^ name)
       | None -> ());
      emit st "(defnode ";
      print_name_params st name params inv.i_annots;
      print_ret st inv.i_ret;
      print_body_stmts st (block_stmts_of inv.i_body);
      emit st ")"
  | EDefValue (name, rhs) ->
      if not (name_ok name) then unpr "binding name %s has no sexpr spelling" name;
      (match rhs with
       | ELocated ((f, l), v) ->
           check_file st f;
           require_line st l ("def " ^ name);
           emit st "(def "; emit st name; emit st " ";
           print_expr st v; emit st ")"
       | v ->
           emit st "(def "; emit st name; emit st " ";
           print_expr st v; emit st ")")
  | EQuote q -> emit st "(quote "; print_expr st q; emit st ")"
  | EForce e -> emit st "(force "; print_expr st e; emit st ")"
  | EDelay e -> emit st "(delay "; print_expr st e; emit st ")"
  | ENode e -> emit st "(node "; print_expr st e; emit st ")"
  | EDo stmts -> emit st "(do"; print_body_stmts st stmts; emit st ")"
  | EWithCaps (c, body) ->
      emit st "(with-caps ";
      print_expr st c;
      print_body_stmts st (block_stmts_of body);
      emit st ")"
  | EWithConfig (m, body) ->
      emit st "(with-config ";
      print_expr st m;
      print_body_stmts st (block_stmts_of body);
      emit st ")"
  | EWithHandler (handlers, body) ->
      emit st "(with-handler [";
      List.iteri (fun i (n, h) ->
        if i > 0 then emit st " ";
        if not (name_ok n) then unpr "handler name %s has no sexpr spelling" n;
        emit st n; emit st " "; print_expr st h)
        handlers;
      emit st "]";
      print_body_stmts st (block_stmts_of body);
      emit st ")"
  | EPerform (name, args) ->
      if not (name_ok name) then unpr "effect name %s has no sexpr spelling" name;
      emit st "(perform "; emit st name;
      List.iter (fun a -> emit st " "; print_expr st a) args;
      emit st ")"
  | EModule stmts -> emit st "(module"; print_body_stmts st stmts; emit st ")"
  | EImport e -> emit st "(import "; print_expr st e; emit st ")"
  | ELoad p -> emit st "(load "; emit st (string_lit p); emit st ")"
  | ELoadModule p -> emit st "(load-module "; emit st (string_lit p); emit st ")"
  | EIsland (uri, pin) ->
      emit st "(island ";
      emit st (string_lit uri);
      (match pin with
       | Some p -> emit st " "; emit st (string_lit p)
       | None -> ());
      emit st ")"
  | EConfig (k, d) ->
      emit st "(config ";
      print_expr st k;
      (match d with
       | Some d -> emit st " "; print_expr st d
       | None -> ());
      emit st ")"
  | ETyped _ ->
      unpr "a bare type annotation has no surface spelling (in either surface)"
  | EApply (fn, args) -> print_apply st fn args

and print_apply st (fn : expr) (args : expr list) : unit =
  match fn, args with
  | ESymbol "vector", elems ->
      emit st "[";
      List.iteri (fun i e -> if i > 0 then emit st " "; print_expr st e) elems;
      emit st "]"
  | ESymbol "hash-map", kvs when List.length kvs mod 2 = 0 ->
      emit st "{";
      let rec pairs i = function
        | [] -> ()
        | k :: v :: rest ->
            if i > 0 then emit st " ";
            print_expr st k; emit st " "; print_expr st v;
            pairs (i + 1) rest
        | [_] -> assert false
      in
      pairs 0 kvs;
      emit st "}"
  | ESymbol "hash-set", elems ->
      emit st "#{";
      List.iteri (fun i e -> if i > 0 then emit st " "; print_expr st e) elems;
      emit st "}"
  | ESymbol s, args when name_ok s ->
      if List.mem s special_form_heads then
        unpr "application of reserved head %s has no sexpr spelling" s;
      emit st "("; emit st s;
      List.iter (fun a -> emit st " "; print_expr st a) args;
      emit st ")"
  | fnexpr, args ->
      emit st "(";
      print_expr st fnexpr;
      List.iter (fun a -> emit st " "; print_expr st a) args;
      emit st ")"

and print_if st c t e =
  emit st "(if ";
  print_expr st c;
  emit st " ";
  print_expr st t;
  (match e with
   | ELiteral VNil -> ()
   | e -> emit st " "; print_expr st e);
  emit st ")"

(* `[name [: ty] value ...]` — let's typed binding vector *)
and print_bindings st (binds : (string * expr) list) : unit =
  List.iteri (fun i (n, v) ->
    if i > 0 then emit st " ";
    if not (name_ok n) then unpr "binding name %s has no sexpr spelling" n;
    emit st n;
    match v with
    | ETyped (v', ty) ->
        emit st " : "; print_expr st ty; emit st " "; print_expr st v'
    | v -> emit st " "; print_expr st v)
    binds

(* `[name value ...]` — let*'s untyped binding vector *)
and print_plain_bindings st (binds : (string * expr) list) : unit =
  List.iteri (fun i (n, v) ->
    if i > 0 then emit st " ";
    if not (name_ok n) then unpr "binding name %s has no sexpr spelling" n;
    emit st n; emit st " "; print_expr st v)
    binds

(* `(p1 [: ty1] p2 ...)` — fn's own parameter parens *)
and print_params st (params : string list) (annots : (string * expr) list) : unit =
  emit st "(";
  let remaining = ref annots in
  List.iteri (fun i p ->
    if i > 0 then emit st " ";
    if not (name_ok p) then unpr "parameter %s has no sexpr spelling" p;
    emit st p;
    match !remaining with
    | (q, ty) :: rest when q = p -> remaining := rest; emit st " : "; print_expr st ty
    | _ -> ())
    params;
  if !remaining <> [] then unpr "unconsumed parameter annotations";
  emit st ")"

(* `(name p1 [: ty1] p2 ...)` — def/defnode's name+params share one paren *)
and print_name_params st (name : string) (params : string list)
    (annots : (string * expr) list) : unit =
  emit st "("; emit st name;
  let remaining = ref annots in
  List.iter (fun p ->
    emit st " ";
    if not (name_ok p) then unpr "parameter %s has no sexpr spelling" p;
    emit st p;
    match !remaining with
    | (q, ty) :: rest when q = p -> remaining := rest; emit st " : "; print_expr st ty
    | _ -> ())
    params;
  if !remaining <> [] then unpr "unconsumed parameter annotations";
  emit st ")"

and print_ret st (ret : expr option) : unit =
  match ret with
  | None -> ()
  | Some ty -> emit st " : "; print_expr st ty

and print_body_stmts st (stmts : expr list) : unit =
  List.iter (fun e -> emit st " "; print_expr st e) stmts

(* ---- public API ---- *)

let print_program ?(source : string = "<?>") (forms : expr list) : string =
  let st = { buf = Buffer.create 1024; line = 1; src = source; strict = true } in
  List.iteri (fun i e ->
    if i > 0 then emit st " ";
    print_expr st e)
    forms;
  if forms <> [] then newline st;
  Buffer.contents st.buf

let print_expr_string (e : expr) : string =
  let st = { buf = Buffer.create 256; line = 1; src = ""; strict = false } in
  print_expr st e;
  Buffer.contents st.buf
