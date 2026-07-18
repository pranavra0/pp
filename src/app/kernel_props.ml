open Pp_runtime
open Pp_frontend
open Pp_kernel
(* Derived generators + kernel properties.

   Three QuickCheck-style generators (one each for [Core_model.value], [pattern]
   and [expr]) and the kernel properties that run under them:

     (i)   INJECTIVITY   distinct ASTs ⇒ distinct content hash
                         (Identity.hash_value / Identity.hash_pattern / Identity.hash_expr — the
                         content key; a collision is a wrong-cache-serve bug, the
                         exact class the length-framed Hasher.hash_concat below exists to kill).
     (ii)  QUOTE RT      rt = Quotation.value_to_expr ∘ Quotation.quote_to_value is TOTAL and
                         IDEMPOTENT — rt (rt e) ≡ rt e (hash-equal). The macro
                         reflect/reify projection reaches a fixpoint in one
                         pass, so a macro re-expanding its own output never
                         drifts. Expr-level identity rt e ≡ e is NOT a
                         law — see quote_roundtrip.
     (iii) PRINT RT      read (print e) is hash-equal to e (locations stripped)
                         on each surface, over the reader-image subset the
                         per-form surface table declares round-trippable; a
                         printer Unprintable is a counted skip, a crash or drift
                         is a failure.
     (iv)  CAPS          a generator over capability VALUES, exhaustive over the
                         kind variant (same ratchet), and the algebra
                         properties: no user-reachable attenuation widens
                         authority (cap_restrict ⊆ its input; cap-compose is the
                         union of its parts — it invents nothing), the with-caps
                         ⊆ gate is sound (an approved request grants nothing the
                         ambient does not), and the node-boundary ban catches an
                         embedded capability/sealed value at any depth.

   THE RATCHET (coverage derived, never enumerated).
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

open Core_model

(* ------------------------------------------------------------------ rng --- *)

type rng = Random.State.t

let ri (st : rng) n = Random.State.int st (max 1 n)
let rb (st : rng) = Random.State.bool st
let choose (st : rng) (xs : 'a list) = List.nth xs (ri st (List.length xs))
let pick (st : rng) (a : 'a array) = a.(ri st (Array.length a))

(* Two generation modes. [Adv]ersarial content stresses the hashers — ':'
   (the old Hasher.hash_concat delimiter), the "absent" env sentinel, length-prefix
   look-alikes ("10:xx"), empty strings, multi-byte chars, the non-finite
   floats — the exact shapes Hasher.hash_concat's length-framing must keep distinct.
   [Faithful] content is what the two surfaces can actually spell (valid
   identifiers, finite floats, no reserved call heads), so the printer
   round-trip property tests real reader-image ASTs rather than the printer's
   deliberate "no brace spelling" refusals. *)
type mode = Adv | Faithful

let adv_names = [| "x"; "y"; "f"; "g"; "+"; "list"; "foo-bar"; "_"; "a:b";
                   "10:xx"; ""; "absent"; "λ" |]
let adv_strings = [| ""; "a"; "b"; ":"; "a:b"; "absent"; "10:xx"; "0:";
                     "hi there"; "λ"; "line\nbreak" |]
(* NaN is excluded: Identity.canonical_float_string merges every NaN payload to "nan"
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
  | Vt_sealed

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
  | Vt_capability -> Runtime_only "authority token; not literal"
  | Vt_thunk -> Runtime_only "mutable evaluation cell"
  | Vt_envmap -> Runtime_only "module export table"
  | Vt_sealed -> Runtime_only "confidential bytes, redacted surface"

let all_value_tags =
  [ Vt_nil; Vt_bool; Vt_int; Vt_float; Vt_string; Vt_keyword; Vt_symbol;
    Vt_pair; Vt_vector; Vt_map; Vt_set;
    Vt_closure; Vt_builtin; Vt_capability; Vt_thunk; Vt_envmap;
    Vt_sealed ]
(* If this fires, a value_tag was added without extending [all_value_tags];
   value_kind's exhaustiveness is what told you a *value* constructor appeared. *)
let () = assert (List.length all_value_tags = 17)

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
         syntax, so Quotation.value_to_expr rejects it (quote round-trip would raise on a
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
      (* Identity.hash_value sorts a set's element hashes, so structural (=) and the
         hash agree only if the element list is itself canonically ordered and
         duplicate-free; otherwise a reordering would read as a spurious
         injectivity collision.  Canonicalize by content hash. *)
      let n = small st in
      let elts = List.init n (fun _ -> g ()) in
      let uniq =
        List.sort_uniq (fun a b -> compare (Identity.hash_value a) (Identity.hash_value b)) elts in
      VSet uniq
  | Vt_closure | Vt_builtin | Vt_capability | Vt_thunk | Vt_envmap
  | Vt_sealed ->
      failwith "gen_value_of_tag: runtime-only value has no syntax"

(* ========================================================= CAPABILITIES == *)

(* The capability algebra as a property, not a unit test.
   The generator is exhaustive over the capability kind variant (same compiler
   ratchet as the AST generators: a new capability constructor makes [cap_kind]
   non-exhaustive, then [gen_cap_of_tag]), and every property below runs over
   its whole output — so a new kind extends all of them at once. *)

(* Capability ratchet — the tag enum, generator, and probe vectors live in
   the [Capability] module (where the abstract type's constructors are
   visible).  Kernel_props calls through, keeping the property definitions
   here and the exhaustiveness ratchet there. *)
type cap_tag = Capability.cap_tag
let cap_kind = Capability.cap_kind
let all_cap_tags = Capability.all_cap_tags
let atomic_cap_tags = Capability.atomic_cap_tags
let cap_paths = [| "/g"; "/g/a"; "/g/a/b"; "/g/x"; "/h"; "/" |]
let cap_hosts = [| "*"; "example.com"; "other.net" |]
let cap_ports = [| None; Some 80; Some 443 |]
let cap_modes = [| Capability.Read; Capability.Write; Capability.ReadWrite |]
let gen_cap = Capability.gen_cap
let cap_probe_vector = Capability.cap_probe_vector
let cap_subseteq_probes = Capability.cap_subseteq_probes

(* Wrap [inner] inside a randomly-shaped syntactic value, [k] levels deep, so
   the node-boundary ban is tested against a capability buried at depth, not
   just sitting at the top. *)
let rec embed_deep (st : rng) (k : int) (inner : value) : value =
  if k <= 0 then inner
  else
    let child = embed_deep st (k - 1) inner in
    match ri st 4 with
    | 0 -> VPair (child, VNil)
    | 1 -> VVector [| VInt (ri st 9); child |]
    | 2 -> VMap [ (VString "k", child) ]
    | _ -> VSet [ child ]

(* The capability properties themselves are defined after [fail] (below), in
   the PROPERTIES section, since they report through it. *)

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
  (* match: the brace surface has both a printer and a reader for it; the
     sexpr surface still has no match spelling defined, so the sexpr
     reader can't re-read a printed match. *)
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
         text fuzzer's domain. *)
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
        List.init (1 + small st) (fun _ ->
          (gen_pattern ~mode st d, (if rb st then Some (e ()) else None), e ())) in
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
  | EMatch (s, arms) -> EMatch (strip_loc s, List.map (fun (p, g, b) -> (p, Option.map strip_loc g, strip_loc b)) arms)

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
  | EMatch (s, arms) ->
      s :: List.concat_map (fun (_, g, b) -> (match g with Some x -> [x] | None -> []) @ [b]) arms

type surface_kind = Sexpr | Braces

(* An expr round-trips on [surface] only if it AND every sub-expr does — a let
   whose body is a match is not sexpr-round-trippable (match has no sexpr
   surface spelling). *)
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
  | EMatch (s, arms) -> Printf.sprintf "(match %s %s)" (dbg s) (l (List.map (fun (p, g, b) -> dbg_pat p ^ (match g with Some x -> " if " ^ dbg x | None -> "") ^ "=>" ^ dbg b) arms))

let debug = try Sys.getenv "KP_DEBUG" = "1" with Not_found -> false

type failure = { prop : string; detail : string }

let failures : failure list ref = ref []
let fail prop detail = failures := { prop; detail } :: !failures

(* ---- (iv) capability algebra --------------------------------------------- *)

let cap_checks = ref 0

let host_services_property () =
  let files = Hashtbl.create 4 in
  Hashtbl.add files "/fake/.pp/cluster/secret" "test-secret";
  Hashtbl.add files "/fake/.pp/cluster/id" "test-cluster";
  let now = ref 1000. in
  let host = Host_services.make
      ~canonical_realpath:(fun p -> "/canonical" ^ p)
      ~unix_time:(fun () -> !now) ~home_dir:(fun () -> "/fake")
      ~read_secret:(Hashtbl.find files)
      ~write_secret:(fun path value ->
        if Hashtbl.mem files path then failwith "fake secret exists";
        Hashtbl.add files path value)
  in
  Cap_token.write_secret_file host "/fake/new-secret" "new";
  if Hashtbl.find_opt files "/fake/new-secret" <> Some "new" then
    fail "host-services-fake" "deterministic secret writer was not used";
  let token = Cap_token.mint host ~secret:"test-secret" ~cluster_id:"test-cluster"
      ~specs:["fs:/scope:ro"] ~ttl_seconds:10 in
  (match Cap_token.token_to_caps host token with
   | Ok [cap] when Capability.check_fs_read cap
                     (Paths.canonicalize ~realpath:(fun x -> x) "/canonical/scope/file") -> ()
   | _ -> fail "host-services-fake" "deterministic fake did not mint and verify authority");
  now := 1011.;
  (match Cap_token.token_to_caps host token with
   | Error msg when String.length msg >= 31 && String.sub msg 0 31 = "cluster token rejected: expired" -> ()
   | _ -> fail "host-services-fake" "deterministic clock did not expire token")

let session_property () =
  let calls_a = ref 0 and calls_b = ref 0 in
  let scheduler_a =
    Scheduler.create ~policy:Scheduler.Serial
      ~remote_dispatch:(fun ~member:_ _ -> incr calls_a)
  in
  let scheduler_b =
    Scheduler.create ~policy:Scheduler.Serial
      ~remote_dispatch:(fun ~member:_ _ -> incr calls_b)
  in
  Scheduler.set_policy scheduler_a (Scheduler.Remote "a");
  Scheduler.dispatch_batch scheduler_a [];
  if Scheduler.policy scheduler_b <> Scheduler.Serial
     || !calls_a <> 1 || !calls_b <> 0 then
    fail "scheduler-isolation" "scheduler handles shared policy or dispatch state";
  let a = Session.create ~scheduler:scheduler_a Evaluator.operations
  and b = Session.create ~scheduler:scheduler_b Evaluator.operations in
  let invocation =
    match Invocation.create ~source_roots:[] ~initial_capabilities:[]
      ~command_argv:[] ~program_argv:[] ~program_files:[]
      ~initial_grant_specs:[] ~program_reconcile_root:None
      ~program_supervise:false ~program_member_name:None
      ~program_desired_object:None ~gc_keep_epochs:1
      ~fenced_policy:Invocation.Abort with
    | Ok invocation -> invocation
    | Error message -> fail "evaluator-instance" message; assert false
  in
  let evaluate session n =
    Dynamic_scope.with_top_level session invocation
      ~f:(fun () -> (Session.core_operations session).eval
          (ELiteral (VInt n)) Environment.empty) ()
  in
  if evaluate a 1 <> VInt 1 || evaluate b 2 <> VInt 2 then
    fail "evaluator-instance" "constructed evaluator operations crossed sessions";
  Dynamic_scope.with_top_level a invocation ~f:(fun () ->
    let read =
      (Identity_types.Cell_id.of_string (Cell.serialize (Cell.Env "X")),
       Identity_types.Observed_hash.of_digest (Observation.env_hash (Some "v"))) in
    Session.clear_observations a;
    Observation.record (Cell.Env "X")
      (Identity_types.Observed_hash.to_string (snd read));
    let recorded = Session.observations a in
    Session.clear_observations a;
    Observation.replay [read];
    if Session.observations a <> recorded then
      fail "observation:record-replay" "record and replay took different paths") ();
  Session.set_macro a "only-a" ([], ELiteral (VInt 1));
  Session.set_probe a "probe" (VInt 1);
  Session.set_probe b "probe" (VInt 2);
  Session.begin_pass a;
  if Session.find_macro b "only-a" <> None
     || Session.find_macro a "only-a" = None
     || Session.find_probe a "probe" <> None
     || Session.find_probe b "probe" <> Some (VInt 2) then
    fail "session-isolation" "independent sessions or pass retention leaked"

let reader_state_property () =
  let sexpr_a = Reader.create ~source:"a.ppl" ()
  and sexpr_b = Reader.create ~source:"b.ppl" () in
  let a_first = Reader.read sexpr_a "(print 1)\n(print 2)" in
  ignore (Reader.read sexpr_b "\n(print 9)");
  let a_second = Reader.read sexpr_a "(print 1)\n(print 2)" in
  if a_first <> a_second then
    fail "reader-state" "interleaved s-expression parsers changed locations";
  let brace_a = Reader_braces.create ~source:"same.pp" ()
  and brace_b = Reader_braces.create ~source:"other.pp" () in
  let source = "try { x <- ok(1); [:ok, x] }" in
  let first = Reader_braces.read brace_a source in
  ignore (Reader_braces.read brace_b
    "try { x <- ok(2); y <- ok(x); [:ok, y] }");
  let second = Reader_braces.read brace_a source in
  if first <> second then
    fail "reader-state" "interleaved brace parsers changed generated names";
  match Reader.read_string ~source:"parity" "(print 1)",
        Reader_braces.read_string ~source:"parity" "print(1)" with
  | [sexpr], [brace] when sexpr = brace -> ()
  | _ -> fail "reader-state" "surface-equivalent forms lost location parity"

let cap_properties (st : rng) ~(count : int) : unit =
  let depth () = 1 + ri st 3 in
  let canon = Paths.canonicalize ~realpath:(fun x -> x) in

  (* Random corpus — the per-tag corpus (which used to call gen_cap_of_tag
     for each tag) is retired now that [Capability.gen_cap] covers every
     constructor through random generation. *)
  let corpus = List.init count (fun _ -> Capability.gen_cap st (depth ())) in

  (* (a) cap_restrict NEVER widens: whatever a restricted value grants,
     its underlying cap already granted. *)
  List.iter (fun c ->
    let scope = canon (pick st cap_paths) in
    let mode = if rb st then None else Some (pick st cap_modes) in
    let r = Capability.restrict ?mode c scope in
    incr cap_checks;
    if not (cap_subseteq_probes r c) then
      fail "cap-restrict-narrows"
        (Printf.sprintf "restrict to %s%s WIDENED authority beyond its input"
           (scope :> string) (match mode with None -> "" | Some m ->
             ":" ^ Capability.mode_name m)))
    corpus;

  (* (b) cap-compose is exactly the UNION of its parts *)
  List.iter (fun _ ->
    let n = 1 + small st in
    let parts = List.init n (fun _ -> Capability.gen_cap st (depth ())) in
    let comp = Capability.compose parts in
    let comp_vec = cap_probe_vector comp in
    let part_vecs = List.map cap_probe_vector parts in
    let union_vec =
      List.fold_left
        (fun acc v -> List.map2 (||) acc v)
        (List.map (fun _ -> false) comp_vec) part_vecs in
    incr cap_checks;
    if comp_vec <> union_vec then
      fail "cap-compose-union"
        "compose does not equal the union of its parts (invented or lost authority)")
    (List.init count (fun _ -> ()));

  (* (c) the with-caps subseteq gate is SOUND *)
  List.iter (fun _ ->
    let requested = Capability.gen_cap st (depth ()) in
    let na = small st in
    let ambient = List.init na (fun _ -> Capability.gen_cap st (depth ())) in
    incr cap_checks;
    if Capability.subseteq requested ambient
       && not (cap_subseteq_probes requested (Capability.compose ambient)) then
      fail "cap-subseteq-sound"
        "cap_subseteq approved a request that grants authority the ambient lacks")
    (List.init count (fun _ -> ()));

  (* (d) the node-boundary ban catches embedded caps/sealed at any depth *)
  List.iter (fun _ ->
    let base = gen_value ~mode:Adv st (2 + ri st 3) in
    incr cap_checks;
    if Value_analysis.contains_authority base then
      fail "node-ban-false-positive"
        "Value_analysis.contains_authority flagged a capability-free value";
    let payload =
      if rb st then VCapability (Capability.gen_cap st (depth ())) else VSealed "s3cr3t" in
    let buried = embed_deep st (ri st 4) payload in
    incr cap_checks;
    if not (Value_analysis.contains_authority buried) then
      fail "node-ban-evaded"
        "Value_analysis.contains_authority missed an embedded capability/sealed value")
    (List.init count (fun _ -> ()))

(* ---- (i) injectivity ---------------------------------------------------- *)

(* Collect [n] samples and bucket them by content hash. Any bucket with two
   structurally distinct members is a real identity collision. Because the
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

(* The macro inverse law.  Let rt = Quotation.value_to_expr ∘ Quotation.quote_to_value —
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
  let rt x = Quotation.value_to_expr (Quotation.quote_to_value x) in
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
        if Identity.hash_expr (strip_loc e1) <> Identity.hash_expr (strip_loc e2) then begin
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
  let target = Identity.hash_expr (strip_loc e) in
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
               if Identity.hash_expr (strip_loc e') <> target then begin
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

(* ---- pinned near-miss corpus (collision witnesses, as ASTs) ------------- *)

(* Shapes that collided (or would, absent length-framing) under a plain
   delimiter join. Each PAIR must hash distinctly. *)
let near_miss_pairs : (expr * expr) list =
  [ (* argv-style: ["a","b"] vs ["a:b"] — the ':' join ambiguity *)
    (EApply (ESymbol "f", [ELiteral (VString "a"); ELiteral (VString "b")]),
     EApply (ESymbol "f", [ELiteral (VString "a:b")]));
    (* env-absent vs the literal value "absent" *)
    (ELiteral (VString "absent"), ELiteral VNil);
    (* symbol "a:b" vs application of a to b would differ anyway; here the
       empty-part case: sym "" vs a one-element apply *)
    (ESymbol "", EApply (ESymbol "", []));
    (* list pattern [a b] vs [ab] (the Identity.hash_pattern delimiter-free join) *)
    (EMatch (ESymbol "x",
             [ (PList ([PVariable "a"; PVariable "b"], None), None, ESymbol "a") ]),
     EMatch (ESymbol "x",
             [ (PList ([PVariable "ab"], None), None, ESymbol "a") ]));
    (* guardless vs guarded arm on the same pattern must not collide *)
    (EMatch (ESymbol "x", [ (PVariable "a", None, ESymbol "a") ]),
     EMatch (ESymbol "x", [ (PVariable "a", Some (ESymbol "a"), ESymbol "a") ]));
    (* let binding name/value framing: {a: 1} vs a binding named "a:1" region *)
    (ELet ([("a", ELiteral (VInt 1))], ESymbol "a"),
     ELet ([("a:1", ELiteral (VInt 1))], ESymbol "a")) ]

let corpus_injectivity () =
  List.iter (fun (a, b) ->
    if Identity.hash_expr a = Identity.hash_expr b then
      fail "injectivity:corpus"
        (Printf.sprintf "near-miss pair collides at %s" (Identity.hash_expr a))
  ) near_miss_pairs

let extracted_model_property () =
  let captured = ref Environment.empty in
  let closure = Environment.make_closure ~name:(Some "self") []
      (ESymbol "self") captured in
  captured := Environment.extend !captured "self" closure;
  (match Environment.lookup !captured "self" with
   | Some found when Identity.hash_value found = Identity.hash_value closure -> ()
   | _ -> fail "core-model:recursive-env" "recursive closure was not recoverable");
  if Value_analysis.contains_authority closure then
    fail "core-model:recursive-env" "recursive closure walk invented authority";
  let quoted = Quotation.quote_to_value (EApply (ESymbol "f", [ELiteral (VInt 1)])) in
  (match Quotation.value_to_expr quoted with
   | EApply (ESymbol "f", [ELiteral (VInt 1)]) -> ()
   | _ -> fail "quotation:roundtrip" "extracted quotation modules changed shape");
  (match Pattern_match.match_pattern (VInt 7) (PVariable "x") with
   | Some [("x", VInt 7)] -> ()
   | _ -> fail "pattern-match:binding" "variable pattern did not bind its value");
  if Presentation.string_of_value (VInt 7) <> "7" then
    fail "presentation:int" "integer presentation changed";
  if Free_vars.SS.elements
       (Free_vars.free_vars (EFn (["x"], EApply (ESymbol "f", [ESymbol "x"]))))
     <> ["f"] then
    fail "free-vars:binding" "function parameter escaped as a free variable"

let observation_boundary_property () =
  let cells =
    [ Cell.File "/x"; RuntimeFile "/x"; Tool "/x"; Tree "/x"; Stat "/x";
      Env "X"; Argv; Config "k"; Handler "h"; Probe "p"; Sealed "/x";
      Domain { name = "d"; sub = "s" }; Unknown "future:x" ]
  in
  List.iter (fun cell ->
    if Cell.parse (Cell.serialize cell) <> cell then
      fail "observation:cell-roundtrip" (Cell.serialize cell)) cells;
  if Cell.parse "proc:legacy" <> Cell.Unknown "proc:legacy" then
    fail "observation:legacy-proc" "legacy proc cell did not conservatively miss";
  if Observation.env_hash None = Observation.env_hash (Some "absent") then
    fail "observation:env-framing" "absence collided with a present value";
  let trace = Trace_repository.{ outcome = Failed;
    result_hash = Identity_types.Object_hash.of_digest "r";
    reads = [ (Identity_types.Cell_id.of_string "file:/x",
               Identity_types.Observed_hash.of_digest "h") ] } in
  let line = "(trace failed \"r\" ((\"file:/x\" . \"h\")))" in
  if Trace_repository.to_line trace <> line
     || Trace_repository.of_line line <> Some trace then
    fail "repository:trace-bytes" "canonical trace bytes changed";
  let a = Cache_policy.create () and b = Cache_policy.create () in
  Cache_policy.enable_why a;
  if not (Cache_policy.why_enabled a) || Cache_policy.why_enabled b then
    fail "cache-policy:isolation" "diagnostic options leaked across handles"

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
  cap_checks := 0;
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
  injectivity ~name:"value" ~hash:Identity.hash_value ~show:dbg_value adv_values;
  injectivity ~name:"pattern" ~hash:Identity.hash_pattern ~show:dbg_pat adv_patterns;
  injectivity ~name:"expr" ~hash:Identity.hash_expr ~show:dbg adv_exprs;
  corpus_injectivity ();
  extracted_model_property ();
  observation_boundary_property ();

  (* (ii) quote round-trip (value-level macro law) *)
  List.iter quote_roundtrip adv_exprs;

  (* (iii) printer round-trip (hash equality, both surfaces) *)
  List.iter print_roundtrip faith_exprs;

  (* (iv) capability algebra — narrowing, union, ⊆-gate soundness, ban *)
  cap_properties st ~count;
  host_services_property ();
  session_property ();
  reader_state_property ();

  (* report *)
  let fs = List.rev !failures in
  Printf.printf
    "kernel-props: seed=%d count=%d | adv:e=%d v=%d p=%d faith:e=%d \
     | forms=%d/%d value-kinds=%d/%d pattern-kinds=%d/%d cap-kinds=%d/%d \
     | print-rt: %d checked, %d printer-refused | cap-checks: %d\n"
    seed count (List.length adv_exprs) (List.length adv_values)
    (List.length adv_patterns) (List.length faith_exprs)
    (List.length all_expr_tags) (List.length all_expr_tags)
    (List.length syntactic_value_tags) (List.length all_value_tags)
    (List.length all_pattern_tags) (List.length all_pattern_tags)
    (List.length all_cap_tags) (List.length all_cap_tags)
    !print_checks !print_skips !cap_checks;
  (match fs with
   | [] -> print_string "kernel-props: OK — injectivity, quote-rt, print-rt, caps all hold\n"
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
