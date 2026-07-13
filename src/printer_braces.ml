(* pp brace printer — renders a `Types.expr` (as produced by the s-expression
   reader) as brace-surface text (SPEC Appendix B) that the brace reader
   (src/reader_braces.ml) re-reads to the structurally IDENTICAL expr — same
   `ELocated` placement, hence the same LAW-20 hash. This is S1's fuzz-gate
   printer and the layer S2's `pp fmt` (and later `pp why`/`pp graph`/REPL
   display) builds on.

   Location preservation: `ELocated ((file, line), _)` drives layout — the
   printer pads with newlines so the construct's first token lands on exactly
   [line], and raises [Unprintable] if a located line was already passed or a
   break is needed where the grammar forbids one (that is a bug in this
   printer's layout, and the fuzz gate would surface it).

   Layout quality (M7 S2 — the migrated files are what humans read after S3):
   the printer runs TWO passes. Pass 1 prints without location enforcement,
   recording every line the strict pass will demand, in demand order (the
   "anchor stream" — demand order is a traversal property, independent of
   layout). Pass 2 prints strictly, consuming the stream; at every layout
   decision the head of the remaining stream is the next line the output
   must not pass, so blocks pretty-print (one statement per line, 2-space
   indentation, closing brace on its own line) exactly as far as the
   vertical slack before the next anchor allows, and pack otherwise —
   short single-statement blocks staying packed one-liners (max_width),
   the closing brace joining the last statement's line when no fresh line
   remains, and comment-occupied lines (`pp fmt`'s [reserved] channel)
   skipped by every break so spliced standalone comments keep lines of
   their own. Anchors are non-decreasing in any printable program
   (require_line never goes backward), so a break taken strictly below the
   next anchor can never overshoot ANY later anchor — the greedy policy is
   safe by construction; a genuine Unprintable inside a pretty attempt
   rolls back (buffer truncation) and reprints packed.

   Separators never trail: wherever a space/`;` used to precede content that
   location padding was about to push onto a later line anyway, the
   separator is elided and the newline itself separates (sep_before /
   leading_anchor below).

   Spelling decisions, each load-bearing for hash preservation (§B.2/B.7):
   - binary operator applications print infix with MINIMAL parentheses per
     the Appendix B precedence table (cmp 4 / add 3 / mul 2; add and mul
     left-associative, cmp non-associative) — an operand parenthesizes only
     when its own level exceeds what its position admits; n-ary operator
     applications print in call form (`+(a, b, c)`) — infix is strictly
     binary and `(+ a b c)` ≠ `(+ (+ a b) c)` under LAW 20.
   - `EIf` always prints as `if`/`else` — the `and`/`or` desugar erases the
     distinction at read time, so re-reading yields the identical tree.
   - quasiquote ASTs print as their lowered form (cons chains, `quote {}`
     blocks, and a plain `quasiquote(...)` application), which the brace
     reader accepts verbatim — no un-lowering is attempted.
   - assert desugars print as the plain `if`/`error` form they already are;
     the baked `at file:line` message string round-trips as a literal.
   - reader-only sugar (`|>`, cells, `reconcile`, `needs`) is never emitted:
     every such row lowers to forms with a canonical spelling below. *)

open Types

exception Unprintable of string

let unpr fmt = Printf.ksprintf (fun s -> raise (Unprintable s)) fmt

(* a packed single-statement block is kept only while its line stays
   readable; past this column the block goes multi-line instead *)
let max_width = 80

let is_digit c = c >= '0' && c <= '9'

(* Words that are grammar in head/statement positions (Appendix B §B.1).
   As bare symbols they print parenthesized — `(if)` — so no following token
   can ever complete them into their form. *)
let reserved = [
  "and"; "assert"; "config"; "def"; "defmacro"; "delay"; "do"; "else"; "fn";
  "force"; "if"; "import"; "island"; "let"; "let*"; "load"; "load-module";
  "mod"; "module"; "needs"; "node"; "or"; "perform"; "quasiquote"; "quote";
  "reconcile"; "splice"; "unquote"; "with-caps"; "with-config"; "with-handler";
]

(* Reserved heads whose call-position spelling would NOT re-read as a plain
   application (the brace reader gives them their special form). No AST the
   sexpr reader produces applies any of these as a function, so hitting this
   is an [Unprintable] bug-guard, not a real limitation. *)
let unsafe_call_heads = [
  "fn"; "def"; "if"; "do"; "node"; "module"; "perform"; "with-caps";
  "with-config"; "with-handler"; "let"; "let*"; "island"; "load";
  "load-module"; "config"; "assert"; "import"; "force"; "delay";
  "and"; "or"; "defmacro";
]

let is_name_char = Reader_braces.is_name_char

let name_ok (s : string) : bool =
  s = "<" || s = "<="
  || (s <> ""
      && String.for_all is_name_char s
      && not (is_digit s.[0])
      && not (String.length s >= 2 && s.[0] = '-'
              && (is_digit s.[1]
                  || (s.[1] = '.' && String.length s >= 3 && is_digit s.[2])))
      && s <> "true" && s <> "false" && s <> "nil")

let infix_binary = ["+"; "-"; "*"; "/"; "mod"; "<"; ">"; "<="; ">="; "="]

(* Appendix B precedence levels (§B.2) for the emitted infix subset. An
   operand position that admits level [k] prints operands of level <= k
   bare and parenthesizes looser ones. Non-infix expressions (literals,
   names, calls, head forms — all parsed as primaries/postfix) are level 0
   and never need operand parentheses. *)
let op_level (op : string) : int =
  if List.mem op ["<"; ">"; "<="; ">="; "="] then 4
  else if op = "+" || op = "-" then 3
  else 2 (* * / mod *)

(* an operand context that admits everything (statements, arguments,
   grouping, map/vector elements, binding values, conditions) *)
let lvl_any = 9

(* ---- literals ---- *)

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

(* A float literal the brace (and sexpr) number lexer reads back to the
   bit-identical double: guarantee a '.' (the lexers' float/int split), and
   verify the round-trip, upgrading to %.17g when the short form loses bits. *)
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
      if k <> "" && String.for_all is_name_char k then ":" ^ k
      else unpr "keyword :%s has no brace spelling" k
  | v -> unpr "value %s is not a literal" (string_of_value v)

(* ---- emitter state ---- *)

type st = {
  buf : Buffer.t;
  mutable line : int;
  mutable col : int;             (* column on the current line (emit never
                                    sees a raw '\n'; string literals escape
                                    theirs, so this is exact) *)
  mutable indent : int;          (* current block indentation (pretty mode) *)
  mutable anch : int list;       (* remaining anchor stream (strict pass) *)
  record : int list ref option;  (* pass 1: record require_line demands *)
  resv : (int, unit) Hashtbl.t;  (* comment-occupied lines (pp fmt): pretty
                                    breaks skip them so spliced standalone
                                    comments keep lines of their own *)
  src : string;      (* location file every ELocated must carry *)
  strict : bool;     (* false: best-effort, ignore location constraints *)
}

let emit st s =
  Buffer.add_string st.buf s;
  st.col <- st.col + String.length s

let newline st = Buffer.add_char st.buf '\n'; st.line <- st.line + 1; st.col <- 0

let emit_indent st = if st.indent > 0 then emit st (String.make st.indent ' ')

(* the next line the output must not pass (head of the anchor stream);
   None once no located content remains *)
let peek_anchor st = match st.anch with a :: _ -> Some a | [] -> None

(* the next line after the current one not reserved for a comment *)
let next_free st =
  let r = ref (st.line + 1) in
  while Hashtbl.mem st.resv !r do incr r done;
  !r

(* Land the next token on [l]; [brk] says whether a line break is
   syntactically permitted right here. *)
let require_line st ~brk (l : int) (what : string) =
  (match st.record with Some r -> r := l :: !r | None -> ());
  if not st.strict then ()
  else begin
    (match st.anch with
     | a :: rest when a = l -> st.anch <- rest
     | _ -> ());
    if l < st.line then
      unpr "cannot place %s at line %d: output is already at line %d" what l st.line
    else if l > st.line then begin
      if not brk then
        unpr "cannot break before %s (it must land on line %d; output is at %d)"
          what l st.line;
      while st.line < l do newline st done
    end
  end

let check_file st (f : string) =
  if st.strict && f <> st.src then
    unpr "located file %S does not match the printed source %S" f st.src

(* ---- fn/def/defnode body inversion (Desugar.assemble_fn_body, reversed) ----

   assemble_fn_body's output shapes are injective over reader-produced ASTs:
   - no annotations: ELocated (loc, body)
   - return annotation: ELocated (loc, ETyped (body, ty))
   - parameter annotations: EDo (checks @ [one of the above]), where each
     check is ELocated (loc, ETyped (ESymbol p, ty))
   (a genuine multi-statement body is EDo *inside* the ELocated wrapper, so
   a bare EDo body can only be the checks case). *)

type inverted = {
  i_loc : (string * int) option;
  i_annots : (string * expr) list;   (* param -> type, in check order *)
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
      (* the checks must be exactly the annotated params, in param order *)
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
  | b ->
      (* not reader-produced (e.g. macro-built); print without a location *)
      { i_loc = None; i_annots = []; i_ret = None; i_body = b }

(* the block rule, reversed: which statements re-read to this body *)
let block_stmts_of (body : expr) : expr list =
  match body with
  | EDo l when List.length l >= 2 -> l
  | e -> [e]

(* The line [e]'s printing will demand BEFORE emitting its first character,
   if any — exactly the constructs whose require_line runs ahead of their
   first token (ELocated wrappers, the def/fn/node family via inversion,
   EDefValue's located rhs; mirrors print_expr below). Used to elide a
   separator when location padding is about to supply the newline anyway,
   and to pad-then-indent pretty statements. *)
let leading_anchor (e : expr) : int option =
  match e with
  | ELocated ((_, l), _) -> Some l
  | EDefValue (_, ELocated ((_, l), _)) -> Some l
  | EFn (ps, b) | EDef (_, ps, b) | EDefNode (_, ps, b) ->
      (try match (invert_fn_body ps b).i_loc with
         | Some (_, l) -> Some l
         | None -> None
       with Unprintable _ -> None)
  | _ -> None

(* emit separator [s] before printing [e] — unless [e]'s own leading
   location is about to pad past this line, in which case the newline
   separates and [s] would only trail *)
let sep_before st (s : string) (e : expr) =
  match leading_anchor e with
  | Some l when st.strict && l > st.line -> ()
  | _ -> emit st s

(* will printing [e] here pad to a later line before its first token? *)
let pads_ahead st (e : expr) =
  match leading_anchor e with
  | Some l when st.strict && l > st.line -> true
  | _ -> false

(* would this expression's printed form start with '{'? (parenthesize it in
   an `if` condition — the condition is parsed brace-free) *)
let rec starts_with_brace (e : expr) : bool =
  match e with
  | EApply (ESymbol "hash-map", args) when List.length args mod 2 = 0 -> true
  | EApply (ESymbol _, _) -> false  (* symbol-headed calls never start with '{' *)
  | EApply (f, _) -> starts_with_brace f
  | ELocated (_, e) -> starts_with_brace e
  | _ -> false

(* defmacro application shape (macro.ml match_defmacro's input) *)
let defmacro_shape (e : expr) : (string * string list) option =
  match e with
  | EApply (ESymbol name, param_exprs) when name_ok name ->
      let ok, params =
        List.fold_left (fun (ok, acc) p ->
          match p with
          | ESymbol s when name_ok s -> (ok, s :: acc)
          | _ -> (false, acc)) (true, []) param_exprs
      in
      if ok then Some (name, List.rev params) else None
  | _ -> None

(* ---- the printer ----

   [lvl] is the operand level the surrounding position admits (op_level
   scale; lvl_any everywhere unconstrained, 0 in annotation-type positions —
   the reader parses those at postfix level, so any infix there must be
   parenthesized). Only the infix case consults it. *)

let rec print_expr st ~brk ?(lvl = lvl_any) (e : expr) : unit =
  match e with
  | ELocated ((f, l), inner) ->
      check_file st f;
      require_line st ~brk l "a located form";
      print_expr st ~brk:false ~lvl inner
  | ELiteral v -> emit st (literal v)
  | ESymbol s ->
      if not (name_ok s) then unpr "symbol %s has no brace spelling" s
      else if List.mem s reserved then (emit st "("; emit st s; emit st ")")
      else emit st s
  | EIf (c, t, e) -> print_if st ~brk c t e
  | ELet (binds, body) ->
      emit st "let (";
      print_bindings st binds;
      emit st ") ";
      print_block st (block_stmts_of body)
  | ELetStar (binds, body) ->
      emit st "let* (";
      print_bindings st binds;
      emit st ") ";
      print_block st (block_stmts_of body)
  | EFn (params, body') ->
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) ->
           check_file st f;
           require_line st ~brk l "fn"
       | None -> ());
      emit st "fn";
      print_params st params inv.i_annots;
      print_ret st inv.i_ret;
      emit st " ";
      print_block st (block_stmts_of inv.i_body)
  | EDef (name, params, body') ->
      if not (name_ok name) then unpr "def name %s has no brace spelling" name;
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) ->
           check_file st f;
           require_line st ~brk l ("def " ^ name)
       | None -> ());
      emit st "def ";
      emit st name;
      print_params st params inv.i_annots;
      print_ret st inv.i_ret;
      emit st " ";
      print_block st (block_stmts_of inv.i_body)
  | EDefNode (name, params, body') ->
      if not (name_ok name) then unpr "node name %s has no brace spelling" name;
      let inv = invert_fn_body params body' in
      (match inv.i_loc with
       | Some (f, l) ->
           check_file st f;
           require_line st ~brk l ("node " ^ name)
       | None -> ());
      emit st "node ";
      emit st name;
      print_params st params inv.i_annots;
      print_ret st inv.i_ret;
      emit st " ";
      print_block st (block_stmts_of inv.i_body)
  | EDefValue (name, rhs) ->
      if not (name_ok name) then unpr "binding name %s has no brace spelling" name;
      (match rhs with
       | ELocated ((f, l), v) ->
           check_file st f;
           require_line st ~brk l ("let " ^ name);
           emit st "let ";
           emit st name;
           emit st " =";
           sep_before st " " v;
           print_expr st ~brk:true v
       | v ->
           emit st "let ";
           emit st name;
           emit st " =";
           sep_before st " " v;
           print_expr st ~brk:true v)
  | EQuote q ->
      emit st "quote {";
      sep_before st " " q;
      print_expr st ~brk:true q;
      emit st " }"
  | EForce e -> emit st "force("; print_expr st ~brk:true e; emit st ")"
  | EDelay e -> emit st "delay("; print_expr st ~brk:true e; emit st ")"
  | ENode e ->
      emit st "node ";
      print_block st (block_stmts_of e)
  | EDo stmts ->
      emit st "do ";
      print_block st stmts
  | EWithCaps (c, body) ->
      emit st "with-caps(";
      print_expr st ~brk:true c;
      emit st ") ";
      print_block st (block_stmts_of body)
  | EWithConfig (m, body) ->
      emit st "with-config(";
      print_expr st ~brk:true m;
      emit st ") ";
      print_block st (block_stmts_of body)
  | EWithHandler (handlers, body) ->
      emit st "with-handler(";
      List.iteri (fun i (n, h) ->
        if i > 0 then emit st ", ";
        if not (name_ok n) then unpr "handler name %s has no brace spelling" n;
        emit st n;
        emit st " =";
        sep_before st " " h;
        print_expr st ~brk:true h)
        handlers;
      emit st ") ";
      print_block st (block_stmts_of body)
  | EPerform (name, args) ->
      if not (name_ok name) then unpr "effect name %s has no brace spelling" name;
      emit st "perform ";
      emit st name;
      print_arglist st args
  | EModule stmts ->
      emit st "module ";
      print_block st stmts
  | EImport e -> emit st "import("; print_expr st ~brk:true e; emit st ")"
  | ELoad p -> emit st "load("; emit st (string_lit p); emit st ")"
  | ELoadModule p -> emit st "load-module("; emit st (string_lit p); emit st ")"
  | EIsland (uri, pin) ->
      emit st "island(";
      emit st (string_lit uri);
      (match pin with
       | Some p -> emit st ", "; emit st (string_lit p)
       | None -> ());
      emit st ")"
  | EConfig (k, d) ->
      emit st "config(";
      print_expr st ~brk:true k;
      (match d with
       | Some d -> emit st ", "; print_expr st ~brk:true d
       | None -> ());
      emit st ")"
  | ETyped _ ->
      unpr "a bare type annotation has no surface spelling (in either surface)"
  | EApply (fn, args) -> print_apply st ~brk ~lvl fn args

and print_apply st ~brk ~lvl fn args =
  ignore brk;
  match fn, args with
  | ESymbol "vector", elems ->
      emit st "[";
      List.iteri (fun i e ->
        if i > 0 then (emit st ","; sep_before st " " e);
        print_expr st ~brk:true e) elems;
      emit st "]"
  | ESymbol "hash-map", kvs when List.length kvs mod 2 = 0 ->
      if kvs = [] then emit st "{}"
      else begin
        emit st "{";
        let rec pairs i = function
          | [] -> ()
          | k :: v :: rest ->
              if i > 0 then (emit st ","; sep_before st " " k);
              print_expr st ~brk:true k;
              (* `->` carries the whitespace-both-sides rule, so its space
                 can never be elided; a value about to pad to a later line
                 is spelled as a group instead (L8: no AST node) so the
                 newline lands inside the parens *)
              emit st " -> ";
              if pads_ahead st v then begin
                emit st "(";
                print_expr st ~brk:true v;
                emit st ")"
              end else print_expr st ~brk:true v;
              pairs (i + 1) rest
          | [_] -> assert false
        in
        pairs 0 kvs;
        emit st "}"
      end
  | ESymbol "defmacro", head :: body when defmacro_shape head <> None ->
      let name, params =
        match defmacro_shape head with Some x -> x | None -> assert false in
      emit st "defmacro ";
      emit st name;
      emit st "(";
      List.iteri (fun i p -> if i > 0 then emit st ", "; emit st p) params;
      emit st ") ";
      print_block st body
  | ESymbol op, [a; b] when List.mem op infix_binary ->
      (* minimal parentheses: wrap only when this operator is looser than
         its position admits. Operand positions per the frozen table: the
         left operand admits the operator's own level for the left-
         associative rows (add, mul) and one tighter on the right;
         comparisons are non-associative, so both operands must be
         strictly tighter than cmp. *)
      let m = op_level op in
      let wrap = m > lvl in
      if wrap then emit st "(";
      let ll, rl = if m = 4 then (3, 3) else (m, m - 1) in
      print_expr st ~brk:true ~lvl:ll a;
      emit st " ";
      emit st op;
      emit st " ";
      (* infix operators carry the whitespace-both-sides rule, so the
         space after [op] can never be elided; an operand about to pad to
         a later line is spelled as a group instead (L8: no AST node) so
         the newline lands inside the parens, not trailing after [op] *)
      if pads_ahead st b then begin
        emit st "(";
        print_expr st ~brk:true b;
        emit st ")"
      end else print_expr st ~brk:true ~lvl:rl b;
      if wrap then emit st ")"
  | ESymbol s, args when name_ok s ->
      if List.mem s unsafe_call_heads then
        unpr "application of reserved head %s has no brace spelling" s;
      emit st s;
      print_arglist st args
  | (EApply _ as f), args ->
      (* call chain: f(x)(y); map/vector-literal heads also postfix cleanly;
         an infix-headed callee parenthesizes itself (postfix is level 1) *)
      print_expr st ~brk:false ~lvl:1 f;
      print_arglist st args
  | f, args ->
      emit st "(";
      print_expr st ~brk:true f;
      emit st ")";
      print_arglist st args

and print_arglist st (args : expr list) : unit =
  emit st "(";
  List.iteri (fun i e ->
    if i > 0 then (emit st ","; sep_before st " " e);
    print_expr st ~brk:true e) args;
  emit st ")"

and print_if st ~brk c t e =
  ignore brk;
  emit st "if ";
  if starts_with_brace c then begin
    emit st "(";
    print_expr st ~brk:true c;
    emit st ")"
  end else
    print_expr st ~brk:false c;
  emit st " ";
  print_block st (block_stmts_of t);
  (match e with
   | ELiteral VNil -> ()
   | EIf (c2, t2, e2) ->
       emit st " else ";
       print_if st ~brk:false c2 t2 e2
   | e ->
       emit st " else ";
       print_block st (block_stmts_of e))

and print_bindings st (binds : (string * expr) list) : unit =
  List.iteri (fun i (n, v) ->
    if i > 0 then emit st ", ";
    if not (name_ok n) then unpr "binding name %s has no brace spelling" n;
    emit st n;
    match v with
    | ETyped (v', ty) ->
        emit st ": ";
        print_expr st ~brk:false ~lvl:0 ty;
        emit st " =";
        sep_before st " " v';
        print_expr st ~brk:true v'
    | v ->
        emit st " =";
        sep_before st " " v;
        print_expr st ~brk:true v)
    binds

and print_params st (params : string list) (annots : (string * expr) list) : unit =
  emit st "(";
  (* each annotated param consumes its (unique-by-order) annotation *)
  let remaining = ref annots in
  List.iteri (fun i p ->
    if i > 0 then emit st ", ";
    if not (name_ok p) then unpr "parameter %s has no brace spelling" p;
    emit st p;
    match !remaining with
    | (q, ty) :: rest when q = p ->
        remaining := rest;
        emit st ": ";
        print_expr st ~brk:false ~lvl:0 ty
    | _ -> ())
    params;
  if !remaining <> [] then unpr "unconsumed parameter annotations";
  emit st ")"

and print_ret st (ret : expr option) : unit =
  match ret with
  | None -> ()
  | Some ty ->
      emit st ": ";
      print_expr st ~brk:false ~lvl:0 ty

(* A block `{ ... }`. In the strict pass, layout is chosen here:
   - a SINGLE-statement block first tries the packed spelling and keeps it
     while the line stays under [max_width] and no location constraint
     objects — the idiomatic one-liner (`{ n + 2 }`, `{ nil }`);
   - otherwise the block pretty-prints (one statement per line, 2-space
     indentation, closing brace on its own line) as far as the vertical
     slack before the next anchor allows;
   - a genuine [Unprintable] inside the pretty attempt rolls everything
     back (buffer truncation) and reprints packed — which reproduces the
     error if it was real rather than layout-induced. *)
and print_block st (stmts : expr list) : unit =
  match stmts with
  | [] -> emit st "{ }"
  | _ when not st.strict -> print_block_packed st stmts
  | stmts ->
      let save_len = Buffer.length st.buf in
      let save_line = st.line in
      let save_col = st.col in
      let save_anch = st.anch in
      let save_ind = st.indent in
      let rollback () =
        Buffer.truncate st.buf save_len;
        st.line <- save_line;
        st.col <- save_col;
        st.anch <- save_anch;
        st.indent <- save_ind
      in
      let packed_narrow_ok () =
        match stmts with
        | [_] ->
            (try
               print_block_packed st stmts;
               (* a keeper only if it genuinely stayed a narrow ONE-liner
                  (nested blocks may have broken the line themselves) *)
               if st.line = save_line && st.col <= max_width then true
               else (rollback (); false)
             with Unprintable _ -> rollback (); false)
        | _ -> false
      in
      if not (packed_narrow_ok ()) then begin
        try print_block_pretty st stmts
        with Unprintable _ ->
          rollback ();
          print_block_packed st stmts
      end

(* One statement per line, 2-space indentation, closing brace on its own
   line. Located statements pad to their exact line (then indent); an
   unlocated statement takes the next comment-free line whenever that
   still lies strictly before the next anchor, and joins the current line
   (`; `-separated) when it does not; the closing brace falls back to
   closing on the last statement's line when no fresh line remains.
   Anchor monotonicity (file header) makes every break safe. *)
and print_block_pretty st (stmts : expr list) : unit =
  emit st "{";
  st.indent <- st.indent + 2;
  List.iteri (fun i stmt ->
    (match leading_anchor stmt with
     | Some l when l > st.line ->
         while st.line < l do newline st done;
         emit_indent st
     | Some _ ->
         (* anchored to THIS line: it cannot move *)
         emit st (if i = 0 then " " else "; ")
     | None ->
         let r = next_free st in
         let can_break =
           match peek_anchor st with None -> true | Some h -> r < h in
         if can_break then begin
           while st.line < r do newline st done;
           emit_indent st
         end else emit st (if i = 0 then " " else "; "));
    print_expr st ~brk:true stmt)
    stmts;
  st.indent <- st.indent - 2;
  let r = next_free st in
  let can_break =
    match peek_anchor st with None -> true | Some h -> r < h in
  if can_break then begin
    while st.line < r do newline st done;
    emit_indent st;
    emit st "}"
  end else emit st " }"

and print_block_packed st (stmts : expr list) : unit =
  (match stmts with
   | first :: _ ->
       emit st "{";
       sep_before st " " first
   | [] -> emit st "{");
  print_seq st stmts;
  emit st " }"

(* newline/';'-separated statement sequence (packed blocks and the top
   level). A statement whose own leading location pads to a later line
   needs no `;` — the newline is the separator. *)
and print_seq st (stmts : expr list) : unit =
  List.iteri (fun i e ->
    if i > 0 then sep_before st "; " e;
    print_expr st ~brk:true e)
    stmts

(* ---- public API ---- *)

(* Print a whole program (the reader's top-level form list) as brace text
   whose re-read yields structurally identical, identically-located forms.
   Two passes: pass 1 (non-strict, packed) records the anchor stream in
   demand order; pass 2 prints strictly against it (see the file header).
   [reserved] lists comment-occupied source lines (`pp fmt`'s side channel,
   src/comments.ml): pretty layout skips them when breaking, so standalone
   comments splice back onto lines of their own. *)
let print_program ?(source : string = "<?>") ?(reserved : int list = [])
    (forms : expr list) : string =
  let resv = Hashtbl.create 16 in
  List.iter (fun l -> Hashtbl.replace resv l ()) reserved;
  let demands = ref [] in
  let st1 = { buf = Buffer.create 1024; line = 1; col = 0; indent = 0;
              anch = []; record = Some demands; resv;
              src = source; strict = false } in
  print_seq st1 forms;
  let st = { buf = Buffer.create 1024; line = 1; col = 0; indent = 0;
             anch = List.rev !demands; record = None; resv;
             src = source; strict = true } in
  print_seq st forms;
  if forms <> [] then newline st;
  Buffer.contents st.buf

(* Best-effort single-expression rendering for display tooling: location
   constraints are not enforced (and not reproduced). *)
let print_expr_string (e : expr) : string =
  let st = { buf = Buffer.create 256; line = 1; col = 0; indent = 0;
             anch = []; record = None; resv = Hashtbl.create 1;
             src = ""; strict = false } in
  print_expr st ~brk:true e;
  Buffer.contents st.buf
