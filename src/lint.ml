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

(** Extract location from an expression, if it has one. *)
let rec get_loc (e : expr) : (string * int) option =
  match e with
  | ELocated (loc, _) -> Some loc
  | _ -> None

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
  (* 1. ?-suffix predicate: should return bool *)
  if ends_with_char name '?' then begin
    (* 1a. is-? double convention *)
    if starts_with_is name then
      warn file line
        (Printf.sprintf "'%s' uses both 'is-' prefix and '?' suffix (redundant convention)"
           name);
    (* 1b. body should look boolean *)
    if not (looks_bool body) then
      warn file line
        (Printf.sprintf "'%s' ends with ? but body does not appear to return bool" name)
  end;
  (* 2. !-suffix effect: body should contain effectful operations *)
  if ends_with_char name '!' then
    if not (has_effect body) then
      warn file line
        (Printf.sprintf "'%s' ends with ! but body appears pure (no perform/! calls)" name);
  (* 6. "loop" helper name *)
  if name = "loop" then
    warn file line
      "function named 'loop' is generic; consider a descriptive name"

(** Extract the nearest source line from an expression or fallback. *)
let line_of ?(fallback=0) (e : expr) : int =
  match get_loc e with Some (_, l) -> l | None -> fallback

(** Recursively walk [e] and emit warnings.
    [~line] is the inherited line context for expressions without their own
    ELocated wrapper (e.g. nested ELet forms inside a def body). *)
let rec check_expr ?(line=0) file (e : expr) : unit =
  let line = line_of ~fallback:line e in
  match e with
  | ELocated (_, e') -> check_expr ~line file e'

  | EDef (name, _params, body) ->
      check_naming file line name body;
      check_result_shape file line body;
      check_expr ~line file body

  | EDefValue (name, rhs) ->
      (match rhs with
       | EFn (_, body) -> check_naming file line name body
       | _ -> ());
      check_expr ~line file rhs

  | ELet (bindings, body) ->
      let depth = let_ladder_depth e in
      if depth >= 3 then
        warn file line
          (Printf.sprintf "let ladder: %d consecutive single-binding lets; consider parallel let" depth);
      List.iter (fun (_, rhs) -> check_expr ~line file rhs) bindings;
      check_expr ~line file body

  | ELetStar (bindings, body) ->
      let depth = let_ladder_depth e in
      if depth >= 2 then
        warn file line
          (Printf.sprintf "let* ladder: %d consecutive single-binding let*s; consider single let*" depth);
      List.iter (fun (_, rhs) -> check_expr ~line file rhs) bindings;
      check_expr ~line file body

  | EApply (fn, args) -> (
      (* L9 sweep: `[…]` reads as a list, not a vector, so
         vector-get/vector-length applied directly to a bracket literal is a
         leftover from the vector era and is now a type error at runtime. Flag
         it statically. A bracket literal lowers to `(list …)`; peel any
         ELocated wrapper the reader attached. *)
      let peel = function ELocated (_, e') -> e' | e -> e in
      (match fn, args with
       | ESymbol (("vector-get" | "vector-length") as op), (first :: _) ->
           (match peel first with
            | EApply (ESymbol "list", _) ->
                warn file line
                  (Printf.sprintf
                     "%s applied to a bracket literal `[…]`, which is a list \
                      (L9), not a vector — use `nth`/`length`, or build a \
                      vector with `vector(…)`" op)
            | _ -> ())
       | _ -> ());
      (* `car`/`cdr` (or `first`/`rest`) applied to a tagged result
         literal `[:ok, _]`/`[:err, _]` — destructure results with `match` or
         `<-`, never by position (SYNTAX §15). *)
      (match fn, args with
       | ESymbol (("car" | "cdr" | "first" | "rest") as op), [arg]
         when tagged_tag arg <> None ->
           warn file line
             (Printf.sprintf
                "`%s` applied to a tagged result `[:%s, …]` — destructure a \
                 result with `match` or `<-`, never `car`/`cdr` (SYNTAX §15)"
                op (match tagged_tag arg with Some t -> t | None -> "?"))
       | _ -> ());
      match fn with
      | ESymbol "if" ->
          (* 5. if not(nil?(x)) → if x *)
          (match args with
          | [cond; _then; _else] ->
              (match cond with
              | EApply (ESymbol "not",
                        [EApply (ESymbol "nil?", [_arg])]) ->
                  warn file line
                    "suggest: use `if x` instead of `if not(nil?(x))`"
              | _ -> ())
          | _ -> ());
          List.iter (check_expr ~line file) args
      | _ ->
          check_expr ~line file fn;
          List.iter (check_expr ~line file) args)

  | EFn (_, body) ->
      check_result_shape file line body;
      check_expr ~line file body

  | EDo exprs ->
      List.iter (check_expr ~line file) exprs

  | EIf (c, t, f) ->
      check_expr ~line file c;
      check_expr ~line file t;
      check_expr ~line file f

  | EWithCaps (cap, body) ->
      check_expr ~line file cap;
      check_expr ~line file body

  | EPerform (_, args) ->
      List.iter (check_expr ~line file) args

  | EWithHandler (handlers, body) ->
      List.iter (fun (_, h) -> check_expr ~line file h) handlers;
      check_expr ~line file body

  | ENode body ->
      check_expr ~line file body

  | EDefNode (_, _, body) ->
      check_expr ~line file body

  | EMatch (scrutinee, arms) ->
      check_expr ~line file scrutinee;
      List.iter (fun (_, guard, body) ->
        (match guard with Some g -> check_expr ~line file g | None -> ());
        check_expr ~line file body) arms

  | EModule exprs ->
      List.iter (check_expr ~line file) exprs

  | EImport e ->
      check_expr ~line file e

  | EQuote e ->
      check_expr ~line file e

  | EForce e ->
      check_expr ~line file e

  | EDelay e ->
      check_expr ~line file e

  | EWithConfig (cfg, body) ->
      check_expr ~line file cfg;
      check_expr ~line file body

  | EConfig (key, default) ->
      check_expr ~line file key;
      (match default with Some d -> check_expr ~line file d | None -> ())

  | ETyped (e, t) ->
      check_expr ~line file e;
      check_expr ~line file t

  | ESymbol s ->
      check_dot_identifier file line s

  | ELiteral _ | ELoad _ | ELoadModule _ | EIsland (_, _) -> ()

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
