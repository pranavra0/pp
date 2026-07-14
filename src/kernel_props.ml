(* MASTER-PLAN A″2 — derived generators + kernel properties.

   Three QuickCheck-style generators (one each for [Types.value], [pattern]
   and [expr]) and the kernel properties that run under them:

     (i)   INJECTIVITY   distinct ASTs ⇒ distinct content hash
                         (hash_value / hash_pattern / hash_expr — the LAW-20
                         key; a collision is a wrong-cache-serve bug, the
                         exact class A″1 length-framed hash_concat to kill).
     (ii)  QUOTE RT      rt = value_to_expr ∘ quote_to_value is TOTAL and
                         IDEMPOTENT — rt (rt e) ≡ rt e (hash-equal). The macro
                         reflect/reify projection reaches a fixpoint in one
                         pass, so a macro re-expanding its own output never
                         drifts (M3/D10). Expr-level identity rt e ≡ e is NOT a
                         law — see quote_roundtrip.
     (iii) PRINT RT      read (print e) is hash-equal to e (locations stripped)
                         on each surface, over the reader-image subset the
                         per-form surface table declares round-trippable; a
                         printer Unprintable is a counted skip, a crash or drift
                         is a failure.

   THE RATCHET (DESIGN §1 principle 8 — coverage derived, never enumerated).
   Each type has a mirror tag enum and two EXHAUSTIVE matches:

     * [*_kind : t -> tag]        — adding a constructor makes this
                                    non-exhaustive; the dev build (warning 8
                                    fatal) fails until the new constructor is
                                    given a tag.
     * [*_gen_of_tag : tag -> t]  — the new tag then makes THIS non-exhaustive;
                                    the build fails again until the new form is
                                    given a generation recipe.
     * [*_surface : tag -> …]     — and this, until the new form declares which
                                    properties it participates in.

   So a single new AST constructor cascades three compile errors, each forcing
   one explicit decision, and once compiled every property covers it at once.
   No per-feature test list exists to fall out of date. *)

open Types

(* ------------------------------------------------------------------ rng --- *)

type rng = Random.State.t

let ri (st : rng) n = Random.State.int st (max 1 n)
let rb (st : rng) = Random.State.bool st
let choose (st : rng) (xs : 'a list) = List.nth xs (ri st (List.length xs))
let pick (st : rng) (a : 'a array) = a.(ri st (Array.length a))

(* Two generation modes. [Adv]ersarial content stresses the hashers — ':'
   (the old hash_concat delimiter), the "absent" env sentinel, length-prefix
   look-alikes ("10:xx"), empty strings, multi-byte chars, the non-finite
   floats — the exact shapes A″1's length-framing must keep distinct.
   [Faithful] content is what the two surfaces can actually spell (valid
   identifiers, finite floats, no reserved call heads), so the printer
   round-trip property tests real reader-image ASTs rather than the printer's
   deliberate "no brace spelling" refusals. *)
type mode = Adv | Faithful

let adv_names = [| "x"; "y"; "f"; "g"; "+"; "list"; "foo-bar"; "_"; "a:b";
                   "10:xx"; ""; "absent"; "λ" |]
let adv_strings = [| ""; "a"; "b"; ":"; "a:b"; "absent"; "10:xx"; "0:";
                     "hi there"; "λ"; "line\nbreak" |]
(* NaN is excluded: canonical_float_string merges every NaN payload to "nan"
   (documented), while OCaml (=) has nan <> nan, so a NaN would read as a
   spurious injectivity collision. -0.0 excluded for symmetry (0.0 = -0.0
   structurally but %h spells them apart). *)
let adv_floats = [| 0.0; 1.0; -1.0; 0.5; 3.14159; 1e10; -2.5; Float.infinity;
                    Float.neg_infinity |]

let faith_names = [| "x"; "y"; "z"; "foo"; "bar"; "baz"; "acc"; "n"; "loop" |]
let faith_strings = [| ""; "a"; "hi"; "a b"; "path/to" |]
let faith_floats = [| 0.0; 1.0; -1.0; 0.5; 3.5; -2.25 |]
(* call heads that collide with no special form / infix operator in either
   surface, so EApply(ESymbol h, _) round-trips as an application (not, say,
   an EIf because the head was "if"). *)
let faith_calls = [| "f"; "g"; "h"; "foo"; "bar"; "compute" |]

let gen_name ~(mode : mode) (st : rng) =
  pick st (match mode with Adv -> adv_names | Faithful -> faith_names)

(* A name for a BINDING position (param, def/let/handler name). In Faithful
   mode these must be pairwise-distinct within any block/param-list, else the
   reader's letrec* block checks reject the printed text ("duplicate definition
   in block", "duplicate parameter") — a non-reader-image AST, not a round-trip
   bug. A monotone counter makes every faithful binding name globally unique,
   which trivially satisfies the per-scope constraint. Reference positions keep
   using gen_name (they need not resolve — the property never evaluates). *)
let fresh_counter = ref 0
let fresh ~(mode : mode) (st : rng) =
  match mode with
  | Adv -> gen_name ~mode st
  | Faithful -> incr fresh_counter; Printf.sprintf "v%d" !fresh_counter
let gen_string ~(mode : mode) (st : rng) =
  pick st (match mode with Adv -> adv_strings | Faithful -> faith_strings)
let gen_float ~(mode : mode) (st : rng) =
  pick st (match mode with Adv -> adv_floats | Faithful -> faith_floats)
let gen_call ~(mode : mode) (st : rng) =
  match mode with Faithful -> pick st faith_calls | Adv -> gen_name ~mode st

(* small list length, biased small so trees stay shallow *)
let small (st : rng) = choose st [0; 1; 1; 2; 2; 3]

(* ============================================================== VALUES ==== *)

type value_tag =
  | Vt_nil | Vt_bool | Vt_int | Vt_float | Vt_string | Vt_keyword | Vt_symbol
  | Vt_pair | Vt_vector | Vt_map | Vt_set
  (* runtime-only: never appears as a literal in parsed source, carries
     functions/refs so is neither (=)-comparable nor generatable as syntax *)
  | Vt_closure | Vt_builtin | Vt_capability | Vt_thunk | Vt_envmap
  | Vt_bytecode | Vt_sealed

(* RATCHET: exhaustive over every value constructor. *)
let value_kind : value -> value_tag = function
  | VNil -> Vt_nil
  | VBool _ -> Vt_bool
  | VInt _ -> Vt_int
  | VFloat _ -> Vt_float
  | VString _ -> Vt_string
  | VKeyword _ -> Vt_keyword
  | VSymbol _ -> Vt_symbol
  | VPair _ -> Vt_pair
  | VVector _ -> Vt_vector
  | VMap _ -> Vt_map
  | VSet _ -> Vt_set
  | VClosure _ -> Vt_closure
  | VBuiltin _ -> Vt_builtin
  | VCapability _ -> Vt_capability
  | VThunk _ -> Vt_thunk
  | VEnvMap _ -> Vt_envmap
  | VBytecode _ -> Vt_bytecode
  | VSealed _ -> Vt_sealed

(* A value constructor's surface story: [Syntactic] values are what a literal
   can denote (so they participate in every property); [Runtime_only] values
   never appear in a parsed AST and carry non-comparable payloads, so they are
   documented-excluded here rather than silently skipped.  RATCHET: exhaustive
   over the tag enum — a new tag forces a decision. *)
type value_surface = Syntactic | Runtime_only of string

let value_surface : value_tag -> value_surface = function
  | Vt_nil | Vt_bool | Vt_int | Vt_float | Vt_string | Vt_keyword
  | Vt_symbol | Vt_pair | Vt_vector | Vt_map | Vt_set -> Syntactic
  | Vt_closure -> Runtime_only "captures a body/env"
  | Vt_builtin -> Runtime_only "carries an OCaml function"
  | Vt_capability -> Runtime_only "authority token, LAW 22 — not literal"
  | Vt_thunk -> Runtime_only "mutable evaluation cell"
  | Vt_envmap -> Runtime_only "module export table"
  | Vt_bytecode -> Runtime_only "compiled unit"
  | Vt_sealed -> Runtime_only "M4 confidential bytes, redacted surface"

let all_value_tags =
  [ Vt_nil; Vt_bool; Vt_int; Vt_float; Vt_string; Vt_keyword; Vt_symbol;
    Vt_pair; Vt_vector; Vt_map; Vt_set;
    Vt_closure; Vt_builtin; Vt_capability; Vt_thunk; Vt_envmap; Vt_bytecode;
    Vt_sealed ]
(* If this fires, a value_tag was added without extending [all_value_tags];
   value_kind's exhaustiveness is what told you a *value* constructor appeared. *)
let () = assert (List.length all_value_tags = 18)

let syntactic_value_tags =
  List.filter (fun t -> value_surface t = Syntactic) all_value_tags

let atomic_value_tags =
  [ Vt_nil; Vt_bool; Vt_int; Vt_float; Vt_string; Vt_keyword; Vt_symbol ]

let rec gen_value ~(mode : mode) (st : rng) (depth : int) : value =
  let tag =
    match mode with
    (* Faithful: only atoms denote a *literal* — a collection value has no
       literal spelling (the reader emits vector(…)/hash-map(…) calls), so an
       ELiteral of one would be unprintable. Adversarial: full syntactic set. *)
    | Faithful -> choose st atomic_value_tags
    | Adv -> if depth <= 0 then choose st atomic_value_tags
             else choose st syntactic_value_tags
  in
  gen_value_of_tag ~mode st depth tag

(* RATCHET: exhaustive over the tag enum.  Runtime-only tags are unreachable
   (never chosen above) but must still be handled — a new value constructor,
   once given a tag and a surface decision, lands here too. *)
and gen_value_of_tag ~(mode : mode) (st : rng) (depth : int) (tag : value_tag) : value =
  let d = depth - 1 in
  let g () = gen_value ~mode st d in
  match tag with
  | Vt_nil -> VNil
  | Vt_bool -> VBool (rb st)
  | Vt_int -> VInt (ri st 400 - 200)
  | Vt_float -> VFloat (gen_float ~mode st)
  | Vt_string -> VString (gen_string ~mode st)
  | Vt_keyword -> VKeyword (gen_name ~mode st)
  | Vt_symbol -> VSymbol (gen_name ~mode st)
  | Vt_pair ->
      (* Proper cons list only: an improper pair (VPair (a, non-list)) has no
         syntax, so value_to_expr rejects it (quote round-trip would raise on a
         literal dotted pair). Improper pairs are exercised by the injectivity
         corpus instead, where they belong. *)
      let n = 1 + small st in
      List.fold_right (fun x acc -> VPair (x, acc))
        (List.init n (fun _ -> g ())) VNil
  | Vt_vector ->
      VVector (Array.init (small st) (fun _ -> g ()))
  | Vt_map ->
      let n = small st in
      VMap (List.init n (fun _ -> (g (), g ())))
  | Vt_set ->
      (* hash_value sorts a set's element hashes, so structural (=) and the
         hash agree only if the element list is itself canonically ordered and
         duplicate-free; otherwise a reordering would read as a spurious
         injectivity collision.  Canonicalize by content hash. *)
      let n = small st in
      let elts = List.init n (fun _ -> g ()) in
      let uniq =
        List.sort_uniq (fun a b -> compare (hash_value a) (hash_value b)) elts in
      VSet uniq
  | Vt_closure | Vt_builtin | Vt_capability | Vt_thunk | Vt_envmap
  | Vt_bytecode | Vt_sealed ->
      failwith "gen_value_of_tag: runtime-only value has no syntax"

(* ============================================================ PATTERNS ==== *)

type pattern_tag = Pt_literal | Pt_variable | Pt_wildcard | Pt_list | Pt_tagged

let pattern_kind : pattern -> pattern_tag = function
  | PLiteral _ -> Pt_literal
  | PVariable _ -> Pt_variable
  | PWildcard -> Pt_wildcard
  | PList _ -> Pt_list
  | PTagged _ -> Pt_tagged

let all_pattern_tags = [ Pt_literal; Pt_variable; Pt_wildcard; Pt_list; Pt_tagged ]
let () = assert (List.length all_pattern_tags = 5)

let rec gen_pattern ~(mode : mode) (st : rng) (depth : int) : pattern =
  let tag =
    if depth <= 0 then choose st [ Pt_literal; Pt_variable; Pt_wildcard ]
    else choose st all_pattern_tags
  in
  gen_pattern_of_tag ~mode st depth tag

and gen_pattern_of_tag ~(mode : mode) (st : rng) (depth : int) (tag : pattern_tag) : pattern =
  let d = depth - 1 in
  match tag with
  | Pt_literal -> PLiteral (gen_value ~mode st d)
  | Pt_variable -> PVariable (gen_name ~mode st)
  | Pt_wildcard -> PWildcard
  | Pt_list ->
      let pats = List.init (small st) (fun _ -> gen_pattern ~mode st d) in
      let rest = if rb st then Some (PVariable (gen_name ~mode st)) else None in
      PList (pats, rest)
  | Pt_tagged ->
      (* Faithful: ≥1 element. A zero-arg tagged pattern [:tag] is not in the
         reader's image — it spells identically to a one-element list pattern
         holding the keyword literal :tag, and the reader resolves that spelling
         to the list pattern.  So [:tag] with no args has no faithful brace
         round-trip; only [:tag, p, …] does. Adv keeps 0 for hash coverage. *)
      let n = match mode with Faithful -> 1 + small st | Adv -> small st in
      PTagged (gen_name ~mode st, List.init n (fun _ -> gen_pattern ~mode st d))

(* ============================================================= EXPRS ====== *)

type expr_tag =
  | Et_literal | Et_symbol | Et_if | Et_let | Et_fn | Et_apply | Et_quote
  | Et_force | Et_with_caps | Et_perform | Et_with_handler | Et_delay | Et_node
  | Et_defnode | Et_do | Et_def | Et_defvalue | Et_letstar | Et_module
  | Et_import | Et_load | Et_load_module | Et_island | Et_with_config
  | Et_config | Et_typed | Et_located | Et_match

let expr_kind : expr -> expr_tag = function
  | ELiteral _ -> Et_literal
  | ESymbol _ -> Et_symbol
  | EIf _ -> Et_if
  | ELet _ -> Et_let
  | EFn _ -> Et_fn
  | EApply _ -> Et_apply
  | EQuote _ -> Et_quote
  | EForce _ -> Et_force
  | EWithCaps _ -> Et_with_caps
  | EPerform _ -> Et_perform
  | EWithHandler _ -> Et_with_handler
  | EDelay _ -> Et_delay
  | ENode _ -> Et_node
  | EDefNode _ -> Et_defnode
  | EDo _ -> Et_do
  | EDef _ -> Et_def
  | EDefValue _ -> Et_defvalue
  | ELetStar _ -> Et_letstar
  | EModule _ -> Et_module
  | EImport _ -> Et_import
  | ELoad _ -> Et_load
  | ELoadModule _ -> Et_load_module
  | EIsland _ -> Et_island
  | EWithConfig _ -> Et_with_config
  | EConfig _ -> Et_config
  | ETyped _ -> Et_typed
  | ELocated _ -> Et_located
  | EMatch _ -> Et_match

(* The surface decision for an expr constructor: does it round-trip through the
   sexpr / brace surface hash-identically?  RATCHET: exhaustive over the tag
   enum — a new form must declare both. (Every form participates in injectivity
   and quote round-trip unconditionally, so those need no per-form flag.) The
   [why] string documents each opt-out; drift here is a compile error, an
   honest opt-out is a one-line edit. *)
type expr_surface = {
  print_sexpr : bool;
  print_braces : bool;
  why : string;             (* rationale when either flag is false *)
}
let both = { print_sexpr = true; print_braces = true; why = "" }
let neither why = { print_sexpr = false; print_braces = false; why }

let expr_surface : expr_tag -> expr_surface = function
  | Et_literal | Et_symbol | Et_if | Et_let | Et_fn | Et_apply | Et_quote
  | Et_force | Et_with_caps | Et_perform | Et_with_handler | Et_delay | Et_node
  | Et_defnode | Et_do | Et_def | Et_defvalue | Et_letstar -> both
  (* match: braces has surface + reader (A3); sexpr surface for match is C4,
     still open — so the sexpr reader can't re-read a printed match. *)
  | Et_match -> { print_sexpr = false; print_braces = true;
                  why = "sexpr match surface is C4 (open)" }
  (* forms with no round-trippable surface spelling on either side *)
  | Et_typed -> neither "a bare (e : ty) has no surface spelling (printer refuses)"
  | Et_located -> neither "location is metadata; quote/print both strip it"
  | Et_config -> neither "$config is B5 (open); config read has no brace head yet"
  | Et_with_config -> neither "with-config has no settled brace surface yet"
  | Et_module -> neither "module is not a top-level brace form"
  | Et_import -> neither "import has no round-trippable brace head yet"
  | Et_load -> neither "load path is a runtime form, not surface-printed"
  | Et_load_module -> neither "load-module is a runtime form, not surface-printed"
  | Et_island -> neither "island is a runtime form, not surface-printed"

let all_expr_tags =
  [ Et_literal; Et_symbol; Et_if; Et_let; Et_fn; Et_apply; Et_quote; Et_force;
    Et_with_caps; Et_perform; Et_with_handler; Et_delay; Et_node; Et_defnode;
    Et_do; Et_def; Et_defvalue; Et_letstar; Et_module; Et_import; Et_load;
    Et_load_module; Et_island; Et_with_config; Et_config; Et_typed; Et_located;
    Et_match ]
let () = assert (List.length all_expr_tags = 28)

(* Faithful mode restricts to forms with a settled surface on the target side
   so the printer round-trip tests reader-image ASTs; injectivity/quote use Adv
   and generate every form. *)
let gen_expr_tags ~(mode : mode) : expr_tag list =
  match mode with
  | Adv -> all_expr_tags
  | Faithful ->
      List.filter (fun t -> let s = expr_surface t in s.print_sexpr || s.print_braces)
        all_expr_tags

let gen_params ~mode (st : rng) = List.init (small st) (fun _ -> fresh ~mode st)

let rec gen_expr ~(mode : mode) (st : rng) (depth : int) : expr =
  let leaves =
    match mode with
    | Adv -> [ Et_literal; Et_symbol; Et_load; Et_load_module; Et_island ]
    | Faithful -> [ Et_literal; Et_symbol ]
  in
  let tag =
    if depth <= 0 then choose st leaves
    else choose st (gen_expr_tags ~mode)
  in
  gen_expr_of_tag ~mode st depth tag

and gen_expr_of_tag ~(mode : mode) (st : rng) (depth : int) (tag : expr_tag) : expr =
  let d = depth - 1 in
  let e () = gen_expr ~mode st d in
  let nm () = gen_name ~mode st in
  let fr () = fresh ~mode st in
  (* binding names must be fresh (unique per block); the VALUE is generated
     first so a self-referential fresh name never accidentally captures. *)
  let bindings () = List.init (small st) (fun _ -> let v = e () in (fr (), v)) in
  match tag with
  | Et_literal -> ELiteral (gen_value ~mode st d)
  | Et_symbol -> ESymbol (nm ())
  | Et_if -> EIf (e (), e (), e ())
  | Et_let -> ELet (bindings (), e ())
  | Et_fn ->
      (* A faithful fn body is a single expr, never a bare EDo: the printer
         reads a do-shaped body back as the desugared parameter-check block
         (invert_fn_body), which only round-trips in the exact reader-assembled
         shape our generator doesn't mint. Multi-statement fn bodies are the
         text fuzzer's domain (tests/054/055). *)
      let body =
        match mode with
        | Adv -> e ()
        | Faithful ->
            let tags = List.filter (fun t -> t <> Et_do) (gen_expr_tags ~mode) in
            gen_expr_of_tag ~mode st d (choose st tags)
      in
      EFn (gen_params ~mode st, body)
  | Et_apply ->
      (* head is a plain call name (never a reserved/special-form symbol) so
         the shape round-trips as an application, not a re-parsed special form *)
      EApply (ESymbol (gen_call ~mode st), List.init (small st) (fun _ -> e ()))
  | Et_quote -> EQuote (e ())
  | Et_force -> EForce (e ())
  | Et_with_caps -> EWithCaps (e (), e ())
  | Et_perform -> EPerform (nm (), List.init (small st) (fun _ -> e ()))
  | Et_with_handler ->
      EWithHandler (List.init (1 + small st) (fun _ -> let v = e () in (fr (), v)), e ())
  | Et_delay -> EDelay (e ())
  | Et_node -> ENode (e ())
  | Et_defnode -> EDefNode (fr (), gen_params ~mode st, e ())
  | Et_do -> EDo (List.init (1 + small st) (fun _ -> e ()))
  | Et_def -> EDef (fr (), gen_params ~mode st, e ())
  | Et_defvalue -> EDefValue (fr (), e ())
  | Et_letstar -> ELetStar (bindings (), e ())
  | Et_module -> EModule (List.init (1 + small st) (fun _ -> e ()))
  | Et_import -> EImport (e ())
  | Et_load -> ELoad (gen_string ~mode st)
  | Et_load_module -> ELoadModule (gen_string ~mode st)
  | Et_island ->
      EIsland (gen_string ~mode st, if rb st then Some (gen_string ~mode st) else None)
  | Et_with_config -> EWithConfig (e (), e ())
  | Et_config -> EConfig (e (), if rb st then Some (e ()) else None)
  | Et_typed -> ETyped (e (), e ())
  | Et_located -> ELocated ((gen_string ~mode st, ri st 1000), e ())
  | Et_match ->
      let arms =
        List.init (1 + small st) (fun _ -> (gen_pattern ~mode st d, e ())) in
      EMatch (e (), arms)

(* Strip source locations so a printed-then-reparsed expr (which the reader
   re-locates) is hash-comparable to the generated original. Exhaustive by
   construction — a new constructor with sub-exprs must be threaded here. *)
let rec strip_loc (e : expr) : expr =
  match e with
  | ELocated (_, e) -> strip_loc e
  | ELiteral _ | ESymbol _ | ELoad _ | ELoadModule _ | EIsland _ -> e
  | EIf (c, t, f) -> EIf (strip_loc c, strip_loc t, strip_loc f)
  | ELet (bs, b) -> ELet (List.map (fun (n, x) -> (n, strip_loc x)) bs, strip_loc b)
  | EFn (ps, b) -> EFn (ps, strip_loc b)
  | EApply (f, a) -> EApply (strip_loc f, List.map strip_loc a)
  | EQuote x -> EQuote (strip_loc x)
  | EForce x -> EForce (strip_loc x)
  | EWithCaps (c, b) -> EWithCaps (strip_loc c, strip_loc b)
  | EPerform (n, a) -> EPerform (n, List.map strip_loc a)
  | EWithHandler (hs, b) ->
      EWithHandler (List.map (fun (n, x) -> (n, strip_loc x)) hs, strip_loc b)
  | EDelay x -> EDelay (strip_loc x)
  | ENode x -> ENode (strip_loc x)
  | EDefNode (n, ps, b) -> EDefNode (n, ps, strip_loc b)
  | EDo xs -> EDo (List.map strip_loc xs)
  | EDef (n, ps, b) -> EDef (n, ps, strip_loc b)
  | EDefValue (n, x) -> EDefValue (n, strip_loc x)
  | ELetStar (bs, b) -> ELetStar (List.map (fun (n, x) -> (n, strip_loc x)) bs, strip_loc b)
  | EModule xs -> EModule (List.map strip_loc xs)
  | EImport x -> EImport (strip_loc x)
  | EWithConfig (m, b) -> EWithConfig (strip_loc m, strip_loc b)
  | EConfig (k, d) -> EConfig (strip_loc k, Option.map strip_loc d)
  | ETyped (x, t) -> ETyped (strip_loc x, strip_loc t)
  | EMatch (s, arms) -> EMatch (strip_loc s, List.map (fun (p, b) -> (p, strip_loc b)) arms)

(* Immediate sub-expressions.  Exhaustive by construction (RATCHET): a new
   constructor carrying sub-exprs must be threaded here, which keeps the
   recursive printability predicate honest. *)
let sub_exprs (e : expr) : expr list =
  match e with
  | ELiteral _ | ESymbol _ | ELoad _ | ELoadModule _ | EIsland _ -> []
  | EIf (c, t, f) -> [c; t; f]
  | ELet (bs, b) | ELetStar (bs, b) -> List.map snd bs @ [b]
  | EFn (_, b) -> [b]
  | EApply (f, a) -> f :: a
  | EQuote x | EForce x | EDelay x | ENode x | EImport x -> [x]
  | EWithCaps (c, b) | EWithConfig (c, b) -> [c; b]
  | EPerform (_, a) -> a
  | EWithHandler (hs, b) -> List.map snd hs @ [b]
  | EDefNode (_, _, b) | EDef (_, _, b) -> [b]
  | EDefValue (_, x) -> [x]
  | EDo xs | EModule xs -> xs
  | EConfig (k, d) -> k :: (match d with Some x -> [x] | None -> [])
  | ETyped (x, t) -> [x; t]
  | ELocated (_, x) -> [x]
  | EMatch (s, arms) -> s :: List.map snd arms

type surface_kind = Sexpr | Braces

(* An expr round-trips on [surface] only if it AND every sub-expr does — a let
   whose body is a match is not sexpr-round-trippable (C4). *)
let rec printable (surface : surface_kind) (e : expr) : bool =
  let s = expr_surface (expr_kind e) in
  let self = match surface with Sexpr -> s.print_sexpr | Braces -> s.print_braces in
  self && List.for_all (printable surface) (sub_exprs e)

(* ========================================================== PROPERTIES ==== *)

(* Best-effort structural rendering for debugging a collision — never raises. *)
let rec dbg_value (v : value) : string =
  match v with
  | VNil -> "nil" | VBool b -> string_of_bool b | VInt n -> string_of_int n
  | VFloat f -> Printf.sprintf "%h" f
  | VString s -> Printf.sprintf "%S" s
  | VKeyword k -> ":" ^ k | VSymbol s -> "'" ^ s
  | VPair (a, d) -> Printf.sprintf "(%s . %s)" (dbg_value a) (dbg_value d)
  | VVector vs -> "#[" ^ String.concat " " (Array.to_list (Array.map dbg_value vs)) ^ "]"
  | VMap kvs -> "{" ^ String.concat ", " (List.map (fun (k, v) -> dbg_value k ^ "->" ^ dbg_value v) kvs) ^ "}"
  | VSet vs -> "#{" ^ String.concat " " (List.map dbg_value vs) ^ "}"
  | _ -> "#<rt>"
let rec dbg_pat (p : pattern) : string =
  match p with
  | PLiteral v -> "lit:" ^ dbg_value v | PVariable s -> "$" ^ s | PWildcard -> "_"
  | PList (ps, r) -> "[" ^ String.concat " " (List.map dbg_pat ps)
                     ^ (match r with Some x -> " ..." ^ dbg_pat x | None -> "") ^ "]"
  | PTagged (t, ps) -> "[:" ^ t ^ " " ^ String.concat " " (List.map dbg_pat ps) ^ "]"
let rec dbg (e : expr) : string =
  let l = String.concat " " in
  match e with
  | ELiteral v -> "L:" ^ dbg_value v
  | ESymbol s -> "S:" ^ s
  | EIf (c, t, f) -> Printf.sprintf "(if %s %s %s)" (dbg c) (dbg t) (dbg f)
  | ELet (bs, b) -> Printf.sprintf "(let [%s] %s)" (l (List.map (fun (n, x) -> n ^ "=" ^ dbg x) bs)) (dbg b)
  | EFn (ps, b) -> Printf.sprintf "(fn [%s] %s)" (l ps) (dbg b)
  | EApply (f, a) -> Printf.sprintf "(%s %s)" (dbg f) (l (List.map dbg a))
  | EQuote x -> "(quote " ^ dbg x ^ ")"
  | EForce x -> "(force " ^ dbg x ^ ")"
  | EWithCaps (c, b) -> Printf.sprintf "(with-caps %s %s)" (dbg c) (dbg b)
  | EPerform (n, a) -> Printf.sprintf "(perform %s %s)" n (l (List.map dbg a))
  | EWithHandler (hs, b) -> Printf.sprintf "(with-handler [%s] %s)" (l (List.map (fun (n, x) -> n ^ "=" ^ dbg x) hs)) (dbg b)
  | EDelay x -> "(delay " ^ dbg x ^ ")"
  | ENode x -> "(node " ^ dbg x ^ ")"
  | EDefNode (n, ps, b) -> Printf.sprintf "(defnode %s [%s] %s)" n (l ps) (dbg b)
  | EDo xs -> "(do " ^ l (List.map dbg xs) ^ ")"
  | EDef (n, ps, b) -> Printf.sprintf "(def %s [%s] %s)" n (l ps) (dbg b)
  | EDefValue (n, x) -> Printf.sprintf "(def %s %s)" n (dbg x)
  | ELetStar (bs, b) -> Printf.sprintf "(let* [%s] %s)" (l (List.map (fun (n, x) -> n ^ "=" ^ dbg x) bs)) (dbg b)
  | EModule xs -> "(module " ^ l (List.map dbg xs) ^ ")"
  | EImport x -> "(import " ^ dbg x ^ ")"
  | ELoad p -> Printf.sprintf "(load %S)" p
  | ELoadModule p -> Printf.sprintf "(load-module %S)" p
  | EIsland (u, p) -> Printf.sprintf "(island %S %s)" u (match p with Some s -> "\"" ^ s ^ "\"" | None -> "nil")
  | EWithConfig (m, b) -> Printf.sprintf "(with-config %s %s)" (dbg m) (dbg b)
  | EConfig (k, d) -> Printf.sprintf "(config %s %s)" (dbg k) (match d with Some x -> dbg x | None -> "-")
  | ETyped (x, t) -> Printf.sprintf "(: %s %s)" (dbg x) (dbg t)
  | ELocated ((f, ln), x) -> Printf.sprintf "@%s:%d%s" f ln (dbg x)
  | EMatch (s, arms) -> Printf.sprintf "(match %s %s)" (dbg s) (l (List.map (fun (p, b) -> dbg_pat p ^ "=>" ^ dbg b) arms))

let debug = try Sys.getenv "KP_DEBUG" = "1" with Not_found -> false

type failure = { prop : string; detail : string }

let failures : failure list ref = ref []
let fail prop detail = failures := { prop; detail } :: !failures

(* ---- (i) injectivity ---------------------------------------------------- *)

(* Collect [n] samples, bucket by content hash; any bucket holding two
   structurally-distinct members is a genuine LAW-20 collision. Because the
   samples are drawn from the (=)-comparable syntactic subset (no NaN, sets
   canonicalized), structural (<>) with a shared hash is exactly a collision. *)
let injectivity (type a) ~(name : string) ~(hash : a -> string)
    ?(show : (a -> string) option) (samples : a list) : unit =
  let tbl : (string, a) Hashtbl.t = Hashtbl.create 4096 in
  List.iter (fun x ->
    let h = hash x in
    match Hashtbl.find_opt tbl h with
    | Some y when y <> x ->
        fail ("injectivity:" ^ name)
          (Printf.sprintf "distinct %s share hash %s" name h);
        (match show with
         | Some f when debug ->
             Printf.eprintf "COLLIDE %s\n  A=%s\n  B=%s\n" h (f x) (f y)
         | _ -> ())
    | _ -> Hashtbl.replace tbl h x
  ) samples

(* ---- (ii) quote round-trip --------------------------------------------- *)

(* The macro inverse law (M3/D10).  Let rt = value_to_expr ∘ quote_to_value —
   the reflect-then-reify projection a macro applies to a captured form.  Two
   guarantees, both total and true for every generated expr:

     TOTALITY   rt never raises on a syntax value.  (The only values with no
                syntax are non-syntactic ones — an improper dotted literal
                pair — which the generator never produces; any raise here is a
                real defect.)
     FIXPOINT   rt is idempotent: rt (rt e) ≡ rt e  (hash-equal).  Plain
                expr-level identity rt e ≡ e is NOT a law and must not be
                asserted: (f x) with f a symbol, [a] as a literal list, and
                (vector …) all quote to the same value and reify to one
                canonical expr — but that canonical expr is a FIXPOINT, so a
                second pass reproduces it exactly.  A macro that re-expands its
                own output therefore never drifts. *)
let quote_roundtrip (e : expr) : unit =
  let rt x = value_to_expr (quote_to_value x) in
  match rt e with
  | exception ex ->
      fail "quote-rt:total"
        (Printf.sprintf "rt raised %s on %s" (Printexc.to_string ex) (dbg e))
  | e1 ->
    match rt e1 with
    | exception ex ->
        fail "quote-rt:total"
          (Printf.sprintf "rt(rt) raised %s on %s" (Printexc.to_string ex) (dbg e))
    | e2 ->
        if hash_expr (strip_loc e1) <> hash_expr (strip_loc e2) then begin
          fail "quote-rt:fixpoint"
            (Printf.sprintf "%s: rt not idempotent" (dbg e));
          if debug then Printf.eprintf "QRT\n  e  =%s\n  e1 =%s\n  e2 =%s\n"
            (dbg e) (dbg e1) (dbg e2)
        end

(* ---- (iii) printer round-trip ------------------------------------------ *)

(* Print skips: a tree the surface table predicts printable, but the printer
   refuses at a finer grain (e.g. an fn body not in the desugared param-check
   shape). Counted and reported so the coverage is never silently narrowed. *)
let print_skips = ref 0
let print_checks = ref 0

let print_roundtrip (e : expr) : unit =
  let target = hash_expr (strip_loc e) in
  let one (surface : surface_kind) ~name ~print ~read =
    if not (printable surface e) then ()   (* documented table exclusion *)
    else begin
      incr print_checks;
      (* An [Unprintable] is the printer honestly declining a shape the coarse
         table over-approximated — skip. Any OTHER print-time exception is a
         printer crash and must NOT be hidden: it fails. A print that SUCCEEDS
         must re-read to the same hash; drift or a parse error on printed text
         is a real round-trip defect. *)
      match
        (try `Ok (print [e]) with
         | Printer_sexpr.Unprintable _ | Printer_braces.Unprintable _ -> `Refused
         | ex -> `Crash ex)
      with
      | `Refused -> incr print_skips
      | `Crash ex ->
          fail ("print-rt:" ^ name)
            (Printf.sprintf "printer crashed (%s) on %s"
               (Printexc.to_string ex) (dbg (strip_loc e)))
      | `Ok text ->
          (match read text with
           | exception ex ->
               fail ("print-rt:" ^ name)
                 (Printf.sprintf "printed text does not re-read (%s) via <<%s>>"
                    (Printexc.to_string ex) text);
               if debug then Printf.eprintf "PRT %s NOREAD %s\n  e =%s\n  txt=<<%s>>\n"
                 name (Printexc.to_string ex) (dbg (strip_loc e)) text
           | [e'] ->
               if hash_expr (strip_loc e') <> target then begin
                 fail ("print-rt:" ^ name)
                   (Printf.sprintf "hash drift for %s via <<%s>>" target text);
                 if debug then
                   Printf.eprintf "PRT %s DRIFT\n  e =%s\n  txt=%s\n  e'=%s\n"
                     name (dbg (strip_loc e)) text (dbg (strip_loc e'))
               end
           | forms ->
               fail ("print-rt:" ^ name)
                 (Printf.sprintf "re-read produced %d forms (expected 1) via <<%s>>"
                    (List.length forms) text))
    end
  in
  one Sexpr ~name:"sexpr"
    ~print:Printer_sexpr.print_program ~read:Reader.read_string;
  one Braces ~name:"braces"
    ~print:Printer_braces.print_program ~read:Reader_braces.read_string

(* ---- pinned near-miss corpus (A″1's collision witnesses, as ASTs) ------- *)

(* Shapes that collided (or would, absent length-framing) under the pre-A″1
   delimiter joins. Each PAIR must hash distinctly. *)
let near_miss_pairs : (expr * expr) list =
  [ (* argv-style: ["a","b"] vs ["a:b"] — the ':' join ambiguity *)
    (EApply (ESymbol "f", [ELiteral (VString "a"); ELiteral (VString "b")]),
     EApply (ESymbol "f", [ELiteral (VString "a:b")]));
    (* env-absent vs the literal value "absent" *)
    (ELiteral (VString "absent"), ELiteral VNil);
    (* symbol "a:b" vs application of a to b would differ anyway; here the
       empty-part case: sym "" vs a one-element apply *)
    (ESymbol "", EApply (ESymbol "", []));
    (* list pattern [a b] vs [ab] (the hash_pattern delimiter-free join) *)
    (EMatch (ESymbol "x",
             [ (PList ([PVariable "a"; PVariable "b"], None), ESymbol "a") ]),
     EMatch (ESymbol "x",
             [ (PList ([PVariable "ab"], None), ESymbol "a") ]));
    (* let binding name/value framing: {a: 1} vs a binding named "a:1" region *)
    (ELet ([("a", ELiteral (VInt 1))], ESymbol "a"),
     ELet ([("a:1", ELiteral (VInt 1))], ESymbol "a")) ]

let corpus_injectivity () =
  List.iter (fun (a, b) ->
    if hash_expr a = hash_expr b then
      fail "injectivity:corpus"
        (Printf.sprintf "near-miss pair collides at %s" (hash_expr a))
  ) near_miss_pairs

(* ============================================================= RUNNER ===== *)

(* Build the per-tag corpus: one canonical instance of EVERY constructor, so
   each property covers each form at least once regardless of random draws.
   This is where the gen_of_tag ratchet pays off — the corpus is derived from
   the tag lists, never hand-listed. *)
let per_tag_exprs ~mode (st : rng) : expr list =
  List.map (gen_expr_of_tag ~mode st 3) (gen_expr_tags ~mode)
let per_tag_values ~mode (st : rng) : value list =
  List.map (gen_value_of_tag ~mode st 3) syntactic_value_tags
let per_tag_patterns ~mode (st : rng) : pattern list =
  List.map (gen_pattern_of_tag ~mode st 3) all_pattern_tags

let run ~(seed : int) ~(count : int) : bool =
  failures := [];
  fresh_counter := 0;
  print_skips := 0;
  print_checks := 0;
  let st = Random.State.make [| seed |] in
  let depth () = 2 + ri st 4 in

  (* Adversarial corpora — hash-stressing content, every constructor. Used by
     injectivity (all three hashers) and the value-level quote round-trip. *)
  let adv_exprs = per_tag_exprs ~mode:Adv st
                  @ List.init count (fun _ -> gen_expr ~mode:Adv st (depth ())) in
  let adv_values = per_tag_values ~mode:Adv st
                   @ List.init count (fun _ -> gen_value ~mode:Adv st (depth ())) in
  let adv_patterns = per_tag_patterns ~mode:Adv st
                     @ List.init count (fun _ -> gen_pattern ~mode:Adv st (depth ())) in

  (* Faithful corpus — reader-image content for the printer round-trip. *)
  let faith_exprs = per_tag_exprs ~mode:Faithful st
                    @ List.init count (fun _ -> gen_expr ~mode:Faithful st (depth ())) in

  (* (i) injectivity over all three hashers + the pinned near-miss corpus *)
  injectivity ~name:"value" ~hash:hash_value ~show:dbg_value adv_values;
  injectivity ~name:"pattern" ~hash:hash_pattern ~show:dbg_pat adv_patterns;
  injectivity ~name:"expr" ~hash:hash_expr ~show:dbg adv_exprs;
  corpus_injectivity ();

  (* (ii) quote round-trip (value-level macro law) *)
  List.iter quote_roundtrip adv_exprs;

  (* (iii) printer round-trip (hash equality, both surfaces) *)
  List.iter print_roundtrip faith_exprs;

  (* report *)
  let fs = List.rev !failures in
  Printf.printf
    "kernel-props: seed=%d count=%d | adv:e=%d v=%d p=%d faith:e=%d \
     | forms=%d/%d value-kinds=%d/%d pattern-kinds=%d/%d \
     | print-rt: %d checked, %d printer-refused\n"
    seed count (List.length adv_exprs) (List.length adv_values)
    (List.length adv_patterns) (List.length faith_exprs)
    (List.length all_expr_tags) (List.length all_expr_tags)
    (List.length syntactic_value_tags) (List.length all_value_tags)
    (List.length all_pattern_tags) (List.length all_pattern_tags)
    !print_checks !print_skips;
  (match fs with
   | [] -> print_string "kernel-props: OK — injectivity, quote-rt, print-rt all hold\n"
   | _ ->
       Printf.printf "kernel-props: %d FAILURE(S)\n" (List.length fs);
       (* dedupe identical (prop,detail) lines for readability *)
       let seen = Hashtbl.create 64 in
       List.iter (fun { prop; detail } ->
         let k = prop ^ "\x00" ^ detail in
         if not (Hashtbl.mem seen k) then begin
           Hashtbl.add seen k ();
           Printf.printf "  [%s] %s\n" prop detail
         end) fs);
  fs = []
