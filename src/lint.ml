(* pp lint — convention checker for pp source files.
   Walks the AST and reports naming/style violations. *)

open Types

type warning = {
  w_file : string;
  w_line : int;
  w_msg : string;
}

let warnings : warning list ref = ref []

let warn file line msg =
  warnings := { w_file = file; w_line = line; w_msg = msg } :: !warnings

(* ---- Helpers ---- *)

(** Strip outer ELocated wrappers to get the underlying expression. *)
let rec strip (e : expr) : expr =
  match e with
  | ELocated (_, e') -> strip e'
  | _ -> e

(** Check whether a function name ends with a given suffix character. *)
let ends_with_char (s : string) (c : char) : bool =
  let len = String.length s in
  len > 0 && s.[len - 1] = c

let starts_with_is (s : string) : bool =
  String.length s >= 3 && String.sub s 0 3 = "is-"

(* ---- Heuristic checks ---- *)

(** Does [e] look like it evaluates to a boolean?
    Heuristic: looks for VBool literals, `not`, `=`, `nil?` calls,
    other `?`-suffixed calls, `if` with bool branches, true/false symbols. *)
let rec looks_bool (e : expr) : bool =
  match strip e with
  | ELiteral (VBool _) -> true
  | ESymbol "true" | ESymbol "false" -> true
  | EApply (fn, _) ->
      let f = match strip fn with ESymbol s -> Some s | _ -> None in
      (match f with
       | Some "not" | Some "=" | Some "nil?" -> true
       | Some s when ends_with_char s '?' -> true
       | _ -> false)
  | EIf (_, t, f) -> looks_bool t && looks_bool f
  | ELet (_, body) -> looks_bool body
  | ELetStar (_, body) -> looks_bool body
  | _ -> false

(** Does [e] contain effectful operations?
    Looks for `perform`, `!`-suffixed calls, `slurp`, `run!`, `write!`. *)
let rec has_effect (e : expr) : bool =
  match strip e with
  | EPerform _ -> true
  | EApply (fn, _) -> (
      match strip fn with
      | ESymbol s ->
          ends_with_char s '!' || s = "perform" || s = "slurp"
          || s = "run!" || s = "write!"
      | _ -> false)
  | ELet (_, body) -> has_effect body
  | ELetStar (_, body) -> has_effect body
  | EDo exprs -> List.exists has_effect exprs
  | EIf (_, t, f) -> has_effect t || has_effect f
  | EFn (_, body) -> has_effect body
  | EDef (_, _, body) -> has_effect body
  | EWithCaps (_, body) -> has_effect body
  | EMatch (scrutinee, arms) ->
      has_effect scrutinee
      || List.exists (fun (_, guard, body) ->
           (match guard with Some g -> has_effect g | None -> false)
           || has_effect body) arms
  | _ -> false

(* ---- tagged-value convention helpers ---- *)

(** The keyword tag of a tagged-list literal `[:tag, …]` (which lowers to
    `(list :tag …)`), if [e] is one. *)
let tagged_tag (e : expr) : string option =
  match strip e with
  | EApply (ESymbol "list", (tagk :: _)) ->
      (match strip tagk with ELiteral (VKeyword k) -> Some k | _ -> None)
  | _ -> None

let is_err_result (e : expr) : bool = tagged_tag e = Some "err"

(** A branch value that is *definitely* a bare (non-result) value: a number,
    string, or bool literal, or a vector/map/plain-list literal. Deliberately
    conservative — keywords (possible sentinels), calls, `if`s, and symbols
    have unknown shape and are NOT treated as bare, to avoid false positives. *)
let is_definitely_bare (e : expr) : bool =
  match strip e with
  | ELiteral (VInt _ | VFloat _ | VString _ | VBool _) -> true
  | EApply (ESymbol "vector", _) -> true
  | EApply (ESymbol "hash-map", _) -> true
  | EApply (ESymbol "list", _) -> tagged_tag e = None
  | _ -> false

(** Collect the tail (result) expression of every branch of a conditional /
    match / block, recursing through nested `if`s (else-if chains), `let`
    bodies, and `do` blocks so an `if/else if/else` chain yields one tail per
    arm. *)
let rec branch_tails (e : expr) : expr list =
  match strip e with
  | EIf (_, t, f) -> branch_tails t @ branch_tails f
  | EMatch (_, arms) -> List.concat_map (fun (_, _, b) -> branch_tails b) arms
  | ELet (_, b) | ELetStar (_, b) -> branch_tails b
  | EDo es -> (match List.rev es with last :: _ -> branch_tails last | [] -> [])
  | other -> [other]

(** A function body that returns `[:err, _]` on one branch and a bare
    value on another mixes result and non-result shapes — flag it. *)
let check_result_shape file line (body : expr) : unit =
  let tails = branch_tails body in
  if List.exists is_err_result tails && List.exists is_definitely_bare tails then
    warn file line
      "inconsistent result shape: one branch returns [:err, _] but another \
       returns a bare value — return [:ok, v] on the success branch (SYNTAX §2)"

(** An identifier containing '.' (a dot-method-call trap or stray dotted
    name). Grant descriptors (the dotted `fs` shorthands) lower away before
    lint sees the AST, so any surviving dotted ESymbol is a real violation. *)
let check_dot_identifier file line (s : string) : unit =
  if String.contains s '.' then
    warn file line
      (Printf.sprintf
         "identifier `%s` contains '.' — there is no dot-method call; use `|>` \
          (a '.' is allowed only inside a `needs` grant descriptor)" s)

(** Does [e] represent a single-binding let (a let ladder rung)? *)
let is_single_let (e : expr) : bool =
  match strip e with
  | ELet ([(_, _)], _) -> true
  | _ -> false

(** Get the body of a let/let* expression. *)
let let_body (e : expr) : expr =
  match strip e with
  | ELet (_, body) -> body
  | ELetStar (_, body) -> body
  | _ -> e

(** Count consecutive single-binding let/let* nests starting from [e]. *)
let rec let_ladder_depth (e : expr) : int =
  if is_single_let e then 1 + let_ladder_depth (let_body e)
  else 0

(* ---- Core checkers ---- *)

(** Check naming conventions for a named function. *)
let check_naming file line name body =
  (* A `?`-suffixed name is a predicate and should return bool. *)
  if ends_with_char name '?' then begin
    (* `is-…?` doubles the predicate convention. *)
    if starts_with_is name then
      warn file line
        (Printf.sprintf "'%s' uses both 'is-' prefix and '?' suffix (redundant convention)"
           name);
    (* The body should look boolean. *)
    if not (looks_bool body) then
      warn file line
        (Printf.sprintf "'%s' ends with ? but body does not appear to return bool" name)
  end;
  (* A `!`-suffixed name is effectful and its body should perform an effect. *)
  if ends_with_char name '!' then
    if not (has_effect body) then
      warn file line
        (Printf.sprintf "'%s' ends with ! but body appears pure (no perform/! calls)" name);
  (* `loop` is a generic helper name. *)
  if name = "loop" then
    warn file line
      "function named 'loop' is generic; consider a descriptive name"

(* ---- Rules ----

   Each rule inspects one (already location-stripped) node and emits any
   warnings it applies to; a rule that does not match the node does nothing.
   [check_expr] runs every rule at every node, then recurses into children,
   so adding a rule is appending one row here. Rules never recurse — the
   single traversal below owns that — so a rule cannot double-visit a subtree.

   Order matters only where two rules can fire on the same node and line:
   `naming` before `result-shape` on a `def`. Every other rule keys off a
   distinct node shape (or a distinct call head), so they never collide. *)

type rule = { id : string; check : string -> int -> expr -> unit }

(** A bracket literal `[…]` reads as a list, not a vector, so
    vector-get/vector-length applied straight to one is a type error at
    runtime (L9). A bracket literal lowers to `(list …)`; peel any ELocated
    wrapper the reader attached. *)
let rule_vector_on_list_literal file line node =
  let peel = function ELocated (_, e') -> e' | e -> e in
  match node with
  | EApply (ESymbol (("vector-get" | "vector-length") as op), (first :: _)) ->
      (match peel first with
       | EApply (ESymbol "list", _) ->
           warn file line
             (Printf.sprintf
                "%s applied to a bracket literal `[…]`, which is a list \
                 (L9), not a vector — use `nth`/`length`, or build a \
                 vector with `vector(…)`" op)
       | _ -> ())
  | _ -> ()

(** `car`/`cdr` (or `first`/`rest`) applied to a tagged result literal
    `[:ok, _]`/`[:err, _]` — destructure results with `match` or `<-`, never
    by position (SYNTAX §15). *)
let rule_car_cdr_on_result file line node =
  match node with
  | EApply (ESymbol (("car" | "cdr" | "first" | "rest") as op), [arg])
    when tagged_tag arg <> None ->
      warn file line
        (Printf.sprintf
           "`%s` applied to a tagged result `[:%s, …]` — destructure a \
            result with `match` or `<-`, never `car`/`cdr` (SYNTAX §15)"
           op (match tagged_tag arg with Some t -> t | None -> "?"))
  | _ -> ()

(** `if not(nil?(x))` is just `if x`. *)
let rule_if_not_nil file line node =
  match node with
  | EApply (ESymbol "if",
            (EApply (ESymbol "not", [EApply (ESymbol "nil?", [_arg])]) :: _then :: _else :: [])) ->
      warn file line "suggest: use `if x` instead of `if not(nil?(x))`"
  | _ -> ()

(** Naming conventions on a named function (`def`, or a `def`-value whose
    right-hand side is a bare `fn`). *)
let rule_naming file line node =
  match node with
  | EDef (name, _params, body) -> check_naming file line name body
  | EDefValue (name, EFn (_, body)) -> check_naming file line name body
  | _ -> ()

(** A function body that mixes `[:err, _]` and bare-value branches. Fires on a
    `def` body and on any `fn` body (so a `def`-value of a `fn` is covered via
    the `fn` node itself). *)
let rule_result_shape file line node =
  match node with
  | EDef (_, _, body) | EFn (_, body) -> check_result_shape file line body
  | _ -> ()

(** A ladder of single-binding `let`/`let*` rungs. *)
let rule_let_ladder file line node =
  match node with
  | ELet _ ->
      let depth = let_ladder_depth node in
      if depth >= 3 then
        warn file line
          (Printf.sprintf "let ladder: %d consecutive single-binding lets; consider parallel let" depth)
  | ELetStar _ ->
      let depth = let_ladder_depth node in
      if depth >= 2 then
        warn file line
          (Printf.sprintf "let* ladder: %d consecutive single-binding let*s; consider single let*" depth)
  | _ -> ()

(** A dotted identifier (there is no dot-method call). *)
let rule_dot_identifier file line node =
  match node with ESymbol s -> check_dot_identifier file line s | _ -> ()

let rules : rule list = [
  { id = "naming";                 check = rule_naming };
  { id = "result-shape";           check = rule_result_shape };
  { id = "let-ladder";             check = rule_let_ladder };
  { id = "vector-on-list-literal"; check = rule_vector_on_list_literal };
  { id = "car-cdr-on-result";      check = rule_car_cdr_on_result };
  { id = "if-not-nil";             check = rule_if_not_nil };
  { id = "dot-identifier";         check = rule_dot_identifier };
]

(** Walk [e]: run every rule against this node, then recurse into its
    children. [~line] is the inherited line context for nodes without their
    own ELocated wrapper (e.g. a nested `let` inside a `def` body); each
    ELocated layer refreshes it, so a node's warnings carry the line of the
    innermost wrapper around it. *)
let rec check_expr ?(line=0) file (e : expr) : unit =
  match e with
  | ELocated ((_, l), inner) -> check_expr ~line:l file inner
  | node ->
      List.iter (fun r -> r.check file line node) rules;
      recurse ~line file node

and recurse ~line file (node : expr) : unit =
  match node with
  | EDef (_, _, body) -> check_expr ~line file body
  | EDefValue (_, rhs) -> check_expr ~line file rhs
  | ELet (bindings, body) | ELetStar (bindings, body) ->
      List.iter (fun (_, rhs) -> check_expr ~line file rhs) bindings;
      check_expr ~line file body
  | EApply (fn, args) ->
      (* An `if` head is the literal symbol `if`, not a user reference, so it
         is not itself walked; every other head is. *)
      (match fn with
       | ESymbol "if" -> ()
       | _ -> check_expr ~line file fn);
      List.iter (check_expr ~line file) args
  | EFn (_, body) -> check_expr ~line file body
  | EDo exprs -> List.iter (check_expr ~line file) exprs
  | EIf (c, t, f) ->
      check_expr ~line file c;
      check_expr ~line file t;
      check_expr ~line file f
  | EWithCaps (cap, body) ->
      check_expr ~line file cap;
      check_expr ~line file body
  | EPerform (_, args) -> List.iter (check_expr ~line file) args
  | EWithHandler (handlers, body) ->
      List.iter (fun (_, h) -> check_expr ~line file h) handlers;
      check_expr ~line file body
  | ENode body -> check_expr ~line file body
  | EDefNode (_, _, body) -> check_expr ~line file body
  | EMatch (scrutinee, arms) ->
      check_expr ~line file scrutinee;
      List.iter (fun (_, guard, body) ->
        (match guard with Some g -> check_expr ~line file g | None -> ());
        check_expr ~line file body) arms
  | EModule exprs -> List.iter (check_expr ~line file) exprs
  | EImport e -> check_expr ~line file e
  | EQuote e -> check_expr ~line file e
  | EForce e -> check_expr ~line file e
  | EDelay e -> check_expr ~line file e
  | EWithConfig (cfg, body) ->
      check_expr ~line file cfg;
      check_expr ~line file body
  | EConfig (key, default) ->
      check_expr ~line file key;
      (match default with Some d -> check_expr ~line file d | None -> ())
  | ETyped (e, t) ->
      check_expr ~line file e;
      check_expr ~line file t
  | ELocated (_, e') -> check_expr ~line file e'
  | ESymbol _ | ELiteral _ | ELoad _ | ELoadModule _ | EIsland (_, _) -> ()

(* ---- Observation-exclusivity (a PRE-lowering token scan) ---- *)

(** Does [path] live under a `stdlib/` directory? The `$` family lowers to the
    bare primitives, and stdlib is where those primitives are legitimately
    used, so the exclusivity check is suppressed there. *)
let is_stdlib_path (path : string) : bool =
  let re_has sub =
    let ls = String.length sub and lp = String.length path in
    let rec go i = i + ls <= lp && (String.sub path i ls = sub || go (i + 1)) in
    go 0
  in
  re_has "stdlib/" || re_has "/stdlib"

(** Warn on a bare world-read primitive (`slurp`, `env-get`, `probe`,
    `config`, `perform tree-observe`) used outside `stdlib/`, pointing at the
    `$` head. This MUST run pre-lowering: after lowering, `$file` and a bare
    `slurp` are the identical AST, so the distinction only exists in the token
    stream. The primitive set is derived from [Surface_tables] (single source).
    A primitive is flagged when it is a call head (next token `(`) or a
    performed effect (previous token `perform`); `config:` (a `with` clause,
    next token `:`) is therefore not flagged. *)
let check_observation_exclusivity file (src : string) : unit =
  if is_stdlib_path file then ()
  else
    let toks =
      try Array.of_list (Reader_braces.lex ~file src) with _ -> [||]
    in
    let n = Array.length toks in
    Array.iteri (fun i (tk : Reader_braces.tok) ->
      match tk.Reader_braces.t with
      | Reader_braces.TName name ->
          (match Surface_tables.observation_primitive name with
           | None -> ()
           | Some suggestion ->
               let next_is_lparen =
                 i + 1 < n && toks.(i + 1).Reader_braces.t = Reader_braces.TLParen
               in
               let prev_is_perform =
                 i > 0 &&
                 (match toks.(i - 1).Reader_braces.t with
                  | Reader_braces.TName "perform" -> true | _ -> false)
               in
               if next_is_lparen || prev_is_perform then
                 warn file tk.Reader_braces.tline
                   (Printf.sprintf
                      "bare `%s` reads the world directly — use `%s` (world \
                       observations go through the $ family; B4)" name suggestion))
      | _ -> ()) toks

(* ---- Public API ---- *)

(** Lint a source file, print warnings to stderr, and exit 0/1. *)
let lint_file (path : string) : unit =
  warnings := [];
  (* Read the file *)
  let ch = open_in_bin path in
  let len = in_channel_length ch in
  let src = really_input_string ch len in
  close_in ch;
  (* Pre-lowering token scan (before the reader lowers $file -> slurp). *)
  check_observation_exclusivity path src;
  (* Parse *)
  let forms =
    try Reader_braces.read_string ~source:path src
    with Failure msg ->
      Printf.eprintf "pp lint: parse error in %s: %s\n%!" path msg;
      exit 1
  in
  (* Walk every top-level form *)
  List.iter (check_expr path) forms;
  (* Print warnings sorted by line *)
  let sorted = List.sort (fun a b -> compare a.w_line b.w_line) !warnings in
  let count = ref 0 in
  List.iter (fun w ->
    incr count;
    Printf.eprintf "%s:%d: warning: %s\n%!" w.w_file w.w_line w.w_msg
  ) sorted;
  if !count > 0 then begin
    Printf.eprintf "%d warning(s) found in %s\n%!" !count path;
    exit 1
  end else begin
    Printf.eprintf "pp lint: no warnings for %s\n%!" path;
    exit 0
  end
