(* pp types — mutually recursive type definitions for the pp runtime *)

(* A capability denial: authority is not part of a computation's identity or
   validity (LAW 15/20), so a cap-denied run must NOT be memoized as a failing
   trace — otherwise granting the missing capability later would still re-serve
   the stale denial. Kept distinct from `Failure` precisely so node evaluation
   can decline to cache it. The registered printer makes it surface to the user
   with the same message text as before. *)
exception Capability_error of string
let () = Printexc.register_printer (function
  | Capability_error msg -> Some msg
  | _ -> None)

(* (exit N): deliberate termination with a status code. A dedicated exception
   (not Failure) so it is never memoized as a failing node trace and never
   picks up error decoration — it unwinds to main, which exits. *)
exception Pp_exit of int

(* ---- Environment ---- *)

(* An environment node with a stable ID, a cached hash, and a list of bindings.
   The hash is computed once (incrementally or from sorted bindings) and never
   changes. Thunks reference env.env_hash for O(1) identity. *)
type env = {
  env_id : int;
  env_hash : string;
  bindings : (string * value) list;
}

(* ---- Expressions — the AST produced by the reader ---- *)

and expr =
  | ELiteral of value       (* self-evaluating literal *)
  | ESymbol of string       (* variable reference *)
  | EIf of expr * expr * expr  (* conditional *)
  | ELet of (string * expr) list * expr  (* parallel let bindings (lazy) *)
  | EFn of string list * expr  (* anonymous function *)
  | EApply of expr * expr list  (* function application *)
  | EQuote of expr          (* quotation: 'x *)
  | EForce of expr          (* explicit force *)
  | EWithCaps of expr * expr  (* (with-caps cap-expr body) — replace the
                                 ambient capability set for body's extent *)
  | EPerform of string * expr list  (* (perform effect-name args...) *)
  | EWithHandler of (string * expr) list * expr  (* effect handler installation *)
  | EDelay of expr          (* explicit delay *)
  | ENode of expr           (* (node body) — persistent cacheable node *)
  | EDefNode of string * string list * expr  (* (defnode (name params...) body...) *)
  | EDo of expr list        (* sequencing — forces each, returns last *)
  | EDef of string * string list * expr  (* (def (name params...) body) *)
  | EDefValue of string * expr  (* (def name value) — non-list head: a value
                                   binding, evaluated at definition time (the
                                   ROADMAP §1 footgun fix). Blocks give it
                                   letrec* scope; the top level is sequential. *)
  | ELetStar of (string * expr) list * expr  (* sequential let — desugared by reader *)
  | EModule of expr list        (* (module body...) — thunk producing an env *)
  | EImport of expr             (* (import mod-expr) — force module, merge env *)
  | ELoad of string             (* (load "file.pp") — eval file in current env *)
  | ELoadModule of string       (* (load-module "file.pp") — eval file as module *)
  | EIsland of string * string option  (* (island <uri> [version]) — remote import *)
  | EWithConfig of expr * expr     (* (with-config {map} body) — ambient config *)
  | EConfig of expr * expr option  (* (config key [default]) — read config *)
  | ETyped of expr * expr          (* (the-expr : type) — type annotation *)
  | ELocated of (string * int) * expr  (* source-located expression *)

(* ---- Values — the runtime representation ---- *)

and value =
  | VNil
  | VBool of bool
  | VInt of int
  | VFloat of float
  | VString of string
  | VKeyword of string
  | VSymbol of string
  | VPair of value * value
  | VVector of value array
  | VMap of (value * value) list  (* association list for simplicity *)
  | VSet of value list
  | VClosure of closure
  | VBuiltin of string * (value list -> value)  (* name + ocaml function *)
  | VCapability of capability
  | VThunk of thunk
  | VEnvMap of (string * value) list  (* module export: list of (name, thunk) pairs *)
  | VBytecode of bytecode

(* ---- Function closure ---- *)
and closure = {
  fn_name : string option;  (* optional name for debugging *)
  params : string list;
  body : expr;              (* tree-walker: actual body; VM: ignored *)
  env : env ref;            (* tree-walker: captured env; VM: ignored *)
  vm_bc : bytecode;         (* VM: bytecode this closure belongs to *)
  vm_offset : int;          (* VM: code offset of function body *)
  vm_frames : frame list;   (* VM: captured frames at closure creation time *)
}

and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;  (* precomputed content-addressable hash *)
  thunk_expr : expr;
  mutable thunk_env : env;
  vm_code : (bytecode * int * frame list) option;  (* VM thunk: (bytecode, code_offset, captured_frames) *)
  type_ann : expr option;              (* lazy gradual type annotation *)
  thunk_loc : (string * int) option;   (* source location for error reporting *)
  config_hash : string;                (* ReaderT config snapshot identity *)
  mutable thunk_persist : bool;         (* persist across runs? true for node, false for delay/let *)
  mutable node_fv : (string * int * int) list;
    (* VM node thunks only: the node's free variables as (name, depth, slot),
       Global encoded as (name, -1, -1). Lets the VM compute the LAW 20 node key
       — code + free-var value hashes — from captured frames, since a VM thunk
       carries bytecode+frames rather than an AST+env. Empty for every other
       thunk. *)
  mutable node_caps : capability list;
    (* Node capture (DESIGN Q11's promise): the ambient capability set at THIS
       process's creation of this `(node e)` occurrence, populated
       unconditionally at both construction sites (ENode eval, VM MAKE_NODE) —
       never left as the default [] for a persist thunk (empty ambient is a
       legitimate captured value, distinct from "not yet captured"). Used by
       force_node as "the caller's capabilities" (LAW 23b): the hit gate and
       the miss recompute's ambient are THIS, not whatever is live in
       current_capabilities at force time. Collapses to the process's
       --grant set when with-caps is unused (current_capabilities never
       changes without it), so tests/011/013/017 are byte-for-byte
       unaffected. Meaningless (unused) on non-persist thunks. *)
}

and thunk_status =
  | Unevaluated
  | Evaluating
  | Evaluated of value

(* ---- Capabilities — authority tokens ---- *)
and capability =
  | CapFilesystem of { path : string; mode : fs_mode }
  | CapNetwork of { protocol : string }
  | CapProcess
  | CapCompose of capability list
  | CapRestrict of { cap : capability; scope : string; mode : fs_mode option }
    (* mode: an optional further fs_mode restriction (in addition to scope).
       None means "inherit whatever the underlying cap grants" (the
       pre-M3 behavior). Constructing one with a mode WIDER than the
       underlying cap holds at scope is rejected (Capabilities.cap_restrict);
       a CapRestrict value on disk/in memory therefore never itself
       represents a widen. *)
  | CapNone

and fs_mode = Read | Write | ReadWrite

(* ---- Bytecode VM types ---- *)
and opcode =
  | PUSH of int              (* constant-pool index *)
  | LOAD_LOCAL of int * int  (* depth, slot *)
  | STORE_LOCAL of int       (* slot in current frame *)
  | LOAD_GLOBAL of int       (* constant-pool index of name *)
  | STORE_GLOBAL of int
  | POP | DUP
  | JUMP of int              (* relative forward/backward offset in opcodes *)
  | JUMP_IF_FALSE of int     (* pop; jump if VNil or VBool false *)
  | FORCE                    (* pop thunk, force via recursive VM, push result *)
  | MAKE_THUNK of int * expr option * ((string * int) option)
                               (* code offset, optional type annotation, optional source location *)
  | MAKE_NODE of int * expr * (string * int * int) list * expr option * ((string * int) option)
                               (* persistent node: code offset, body AST (for the
                                  code hash), free-var descriptors (name,depth,slot;
                                  Global = -1,-1), type annotation, source location *)
  | MAKE_CLOSURE of int * int(* code offset, nparams *)
  | CALL of int | TAIL_CALL of int | RETURN | HALT
  | WITH_CAPS of int         (* body code offset: with-caps' ⊆-gated, replace-
                                 ambient region — a nested run_isolated call
                                 (not a flat ENTER/EXIT pair), so an OCaml
                                 try/with around it restores the ambient on
                                 EVERY exit, including a raised exception
                                 (LAW 27), not just normal return/tail-call *)
  | PERFORM of int * int     (* cp idx of effect name, nargs *)
  | PUSH_HANDLER of int      (* n (name,closure) pairs already on stack *)
  | POP_HANDLER
  | MAKE_MODULE of int       (* nexports; pops name+thunk pairs, pushes VEnvMap *)
  | IMPORT                   (* pop VEnvMap, merge bindings into current frame *)
  | LOAD_FILE of int | LOAD_MODULE_FILE of int  (* cp idx of path *)
  | ISLAND of int * int option (* cp idx of uri, cp idx of inline pin (D2);
                                  resolves via Island at run time, then
                                  module-evaluates the pinned entry.pp *)
  | PUSH_CONFIG              (* pop config-map, push onto config stack *)
  | POP_CONFIG               (* pop config stack *)
  | READ_CONFIG              (* pop key from stack; push config value or VNil *)

and bytecode = {
  consts : value array;
  code : opcode array;
  nparams_of : (int, int) Hashtbl.t;          (* code offset -> param count *)
  param_names_of : (int, string list) Hashtbl.t;  (* code offset -> param names *)
  closure_names_of : (int, string) Hashtbl.t;  (* code offset -> optional def name *)
}

and frame = {
  mutable slots : value array;
  mutable len : int;
}

(* ---- Compiler types (referenced by primitives.ml) ---- *)

type cenv = string list list

type def_info = {
  name : string;
  slot : int;
}

type comp_state = {
  mutable ops : opcode list;
  mutable const_ht : (string, int) Hashtbl.t;
  mutable consts : value list;
  mutable nparams_of : (int, int) Hashtbl.t;
  mutable param_names_of : (int, string list) Hashtbl.t;
  mutable closure_names_of : (int, string) Hashtbl.t;
  mutable cenv : cenv;
}

let fresh_comp_state () = {
  ops = [];
  const_ht = Hashtbl.create 128;
  consts = [];
  nparams_of = Hashtbl.create 16;
  param_names_of = Hashtbl.create 16;
  closure_names_of = Hashtbl.create 16;
  cenv = [];
}


(* =================================================================== *)
(*  Environment helpers — must come after the type block                *)
(* =================================================================== *)

(* Global counter for unique environment IDs *)
let env_counter = ref 0
let fresh_env_id () =
  let id = !env_counter in
  env_counter := id + 1;
  id

(* Empty environment — root of all environment chains *)
let empty_env =
  { env_id = fresh_env_id ();
    env_hash = Digest.string "env:empty";
    bindings = [] }


(* =================================================================== *)
(*  Content-addressing: hashing for values, expressions, capabilities  *)
(*  Must come after all types AND before extend_env (which calls       *)
(*  hash_value).                                                        *)
(* =================================================================== *)

let hex_encode (s : string) : string =
  let chars = "0123456789abcdef" in
  String.init (String.length s * 2) (fun i ->
    let c = Char.code s.[i / 2] in
    let nibble = if i mod 2 = 0 then c lsr 4 else c land 0xf in
    chars.[nibble])

let hash_string (s : string) : string =
  hex_encode (Cryptokit.hash_string (Cryptokit.Hash.sha256 ()) s)

let hash_concat (parts : string list) : string =
  hash_string (String.concat ":" parts)

(* THE canonical float spelling — bit-exact via %h (so two doubles that differ
   anywhere in their bits hash and encode differently; string_of_float's ~12
   significant digits could collide two distinct doubles into one LAW-20 key
   and serve a wrong cached result), with nan/inf/-inf as fixed tokens (NaN
   payloads deliberately merge). Shared by hash_value below and the store
   codec (Codec.encode_float) so content identity and on-disk bytes can never
   disagree about whether two floats are the same value. *)
let canonical_float_string (f : float) : string =
  if f <> f then "nan"
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else Printf.sprintf "%h" f

(* Dummy bytecode for tree-walker closures — also the sentinel hash_value uses
   (by physical equality) to tell a tree-walker closure from a VM one. *)
let dummy_bytecode = { consts = [||]; code = [||]; nparams_of = Hashtbl.create 0; param_names_of = Hashtbl.create 0; closure_names_of = Hashtbl.create 0 }

(* Content identity of a compiled bytecode unit: the marshalled consts+code
   arrays. In-memory identity only — these bytes are never persisted (the
   store is Marshal-free since M2.2), so Marshal's same-version/same-arch
   caveat is confined to this process. *)
let hash_bytecode (bc : bytecode) : string =
  try hash_string (Marshal.to_string (bc.consts, bc.code) [Marshal.Closures])
  with _ -> hash_string "bytecode:unmarshalable"

let rec hash_expr (e : expr) : string =
  match e with
  | ELiteral v -> hash_concat ["lit"; hash_value v]
  | ESymbol s -> hash_concat ["sym"; s]
  | EIf (c, t, f) -> hash_concat ["if"; hash_expr c; hash_expr t; hash_expr f]
  | ELet (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        hash_concat ["let_bind"; n; hash_expr e]
      ) bindings in
      hash_concat ("let" :: bparts @ [hash_expr body])
  | EFn (params, body) ->
      hash_concat ["fn"; hash_concat ("params" :: params); hash_expr body]
  | EApply (fn, args) ->
      let arg_hashes = List.map hash_expr args in
      hash_concat ("apply" :: hash_expr fn :: arg_hashes)
  | EQuote e -> hash_concat ["quote"; hash_expr e]
  | EForce e -> hash_concat ["force"; hash_expr e]
  | EWithCaps (caps, body) ->
      hash_concat ["with_caps"; hash_expr caps; hash_expr body]
  | EPerform (name, args) ->
      let arg_hashes = List.map hash_expr args in
      hash_concat ("perform" :: name :: arg_hashes)
  | EWithHandler (handlers, body) ->
      let hparts = List.map (fun (n, e) ->
        hash_concat ["handler"; n; hash_expr e]
      ) handlers in
      hash_concat ("with_handler" :: hparts @ [hash_expr body])
  | EDelay e -> hash_concat ["delay"; hash_expr e]
  | ENode e -> hash_concat ["node"; hash_expr e]
  | EDefNode (name, params, body) ->
      hash_concat ["defnode"; name; hash_concat ("params" :: params); hash_expr body]
  | EDo exprs ->
      hash_concat ("do" :: List.map hash_expr exprs)
  | EDef (name, params, body) ->
      hash_concat ["def"; name; hash_concat ("params" :: params); hash_expr body]
  | EDefValue (name, e) ->
      hash_concat ["def-value"; name; hash_expr e]
  | ELetStar (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        hash_concat ["let_star_bind"; n; hash_expr e]
      ) bindings in
      hash_concat ("let_star" :: bparts @ [hash_expr body])
  | EModule exprs ->
      hash_concat ("module" :: List.map hash_expr exprs)
  | EImport mod_expr ->
      hash_concat ["import"; hash_expr mod_expr]
  | ELoad path ->
      hash_concat ["load"; path]
  | ELoadModule path ->
      hash_concat ["load_module"; path]
  | EIsland (uri, pin) ->
      hash_concat ["island"; uri; (match pin with Some p -> p | None -> "")]
  | EWithConfig (map_expr, body) ->
      hash_concat ["with_config"; hash_expr map_expr; hash_expr body]
  | EConfig (key_expr, default) ->
      hash_concat ["config"; hash_expr key_expr; (match default with Some d -> hash_expr d | None -> "")]
  | ETyped (e, ty) ->
      hash_concat ["typed"; hash_expr e; hash_expr ty]
  | ELocated ((file, line), e) ->
      hash_concat ["located"; file; string_of_int line; hash_expr e]

and hash_value (v : value) : string =
  (* Frames already being hashed (physical identity): a closure captured in a
     frame that captures the closure would otherwise recurse forever. A
     re-encountered frame contributes a fixed cycle marker — deterministic,
     because the traversal order is structural. *)
  let visited_frames : frame list ref = ref [] in
  let rec hash_frame (fr : frame) : string =
    if List.memq fr !visited_frames then hash_string "frame:cycle"
    else begin
      visited_frames := fr :: !visited_frames;
      let live = Array.sub fr.slots 0 fr.len in
      hash_concat ("frame" :: Array.to_list (Array.map hash_val live))
    end
  and hash_val v =
    match v with
    | VThunk t ->
        (match t.thunk_hash with
         | Some h -> h  (* O(1): use precomputed content-addressable hash *)
         | None ->
             (match t.vm_code with
              | Some (bc, offset, frames) ->
                  (* VM thunk: its AST/env fields are placeholders — identity is
                     the bytecode region + entry offset + captured frames. *)
                  hash_concat
                    (["vm-thunk"; hash_bytecode bc; string_of_int offset]
                     @ List.map hash_frame frames)
              | None ->
                  (* Should not happen in practice — all thunks go through
                     make_thunk_ca. Fall back to structural hash using the
                     env's cached hash. *)
                  hash_concat ["thunk"; hash_expr t.thunk_expr; t.thunk_env.env_hash; t.config_hash]))
    | VNil -> hash_string "nil"
    | VBool true -> hash_string "bool:true"
    | VBool false -> hash_string "bool:false"
    | VInt n -> hash_concat ["int"; string_of_int n]
    | VFloat f -> hash_concat ["float"; canonical_float_string f]
    | VString s -> hash_concat ["string"; s]
    | VKeyword k -> hash_concat ["keyword"; k]
    | VSymbol s -> hash_concat ["symbol"; s]
    | VPair (car, cdr) ->
        hash_concat ["pair"; hash_val car; hash_val cdr]
    | VVector vs ->
        let parts = Array.to_list (Array.map hash_val vs) in
        hash_concat ("vector" :: parts)
    | VMap kvs ->
        let sorted = List.sort (fun (k1,_) (k2,_) ->
          String.compare (hash_val k1) (hash_val k2)
        ) kvs in
        let parts = List.map (fun (k, v) ->
          hash_concat [hash_val k; hash_val v]
        ) sorted in
        hash_concat ("map" :: parts)
    | VSet vs ->
        let sorted = List.sort String.compare (List.map hash_val vs) in
        hash_concat ("set" :: sorted)
    | VClosure { fn_name; params; body; env; vm_bc; vm_offset; vm_frames } ->
        let name_part = match fn_name with Some n -> n | None -> "anon" in
        if vm_bc == dummy_bytecode then
          hash_concat ["closure"; name_part;
                       hash_concat ("params" :: params);
                       hash_expr body;
                       (!env).env_hash]
          (* D6: the captured environment IS part of a closure's identity — two
             closures with identical code but different captures must hash
             differently, or an enclosing content-addressed thunk collides and
             returns a stale result (tests/009). We fold in the captured env's
             PRECOMPUTED env_hash: O(1), no traversal, and no recursion back into
             hash_value (env_hash is a fixed string computed at extend_env time),
             so recursive/mutual closures terminate. This over-approximates —
             it captures the whole visible env, not just free variables — which
             is sound (at worst fewer cache hits); free-var-precise keying is a
             later optimization. *)
        else
          (* VM closure: body is a placeholder (ELiteral VNil) and env is empty —
             the code lives in vm_bc at vm_offset and the captures in vm_frames.
             Hashing the placeholders made ALL same-arity VM closures collide,
             which let a node cached under handler A be served under handler B
             (LAW 26 trace cells compare handler hashes). Identity here is the
             bytecode unit + entry offset + cycle-guarded captured frames. *)
          hash_concat
            (["vm-closure"; name_part;
              hash_concat ("params" :: params);
              hash_bytecode vm_bc;
              string_of_int vm_offset]
             @ List.map hash_frame vm_frames)
    | VBuiltin (name, _) ->
        hash_concat ["builtin"; name]
    | VCapability cap ->
        hash_capability cap
    | VEnvMap bindings ->
        let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b) bindings in
        let parts = List.map (fun (name, v) ->
          hash_concat [name; hash_val v]
        ) sorted in
        hash_concat ("envmap" :: parts)
    | VBytecode bc ->
        hash_concat ["bytecode"; string_of_int (Array.length bc.code)]
  in
  hash_val v

and hash_capability (c : capability) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> "r" | Write -> "w" | ReadWrite -> "rw" in
      hash_concat ["cap_fs"; path; m]
  | CapNetwork { protocol } ->
      hash_concat ["cap_net"; protocol]
  | CapProcess -> hash_string "cap_process"
  | CapCompose caps ->
      hash_concat ("cap_compose" :: List.map hash_capability caps)
  | CapRestrict { cap; scope; mode } ->
      let m = match mode with
        | None -> "any" | Some Read -> "r" | Some Write -> "w" | Some ReadWrite -> "rw" in
      hash_concat ["cap_restrict"; hash_capability cap; scope; m]
  | CapNone -> hash_string "cap_none"

(* ---- Node-boundary capability ban (SPEC LAW 20, M3) ----

   Structural scan for an embedded VCapability, used by BOTH halves of the
   node boundary: the free-var ban (node_key_of / vm_node_key, import side)
   and the result ban (run_node_body, export side). Closure-env-aware — a
   capability could be bound in a closure's captured environment/frames, not
   just sitting directly in the scanned value — but it must NEVER force an
   Unevaluated thunk (LAW 14): a capability hidden behind an unforced thunk
   is invisible to this check, a documented residual (the layer-1 gap;
   layers 2/3 — the result ban and the use-time ⊆ gates — are the actual
   security floor, PLAN-m3-attenuation.md).

   BOTH closure representations need a cycle guard, not just the VM's:
   - VM closures carry their capture as `vm_frames`, a mutable frame graph a
     recursive closure can make self-referential; guarded with the SAME
     physical-identity visited-list `hash_value`'s `hash_frame` uses above.
   - Tree-walker closures carry their capture as `env.bindings` — and,
     surprisingly, THIS CAN CYCLE TOO: a top-level `(def f ...)` passes
     `make_closure` the very `env ref` cell that `eval_expressions` is about
     to mutate to `extend_env`-cons `f`'s own binding onto (the letrec/mutual-
     recursion trick both backends' top-level driver relies on), so
     `f`'s captured env ends up containing `f` itself as its head binding —
     walking it without a guard recurses forever (found by tests/024's
     101-TU build going through this scan for every node's closure-valued
     free vars: an immediate Stack overflow before this guard was added).
     Guarded by `env_id` (unique per env node, `Types.fresh_env_id`) in a
     hashtable — no physical/structural sharing needed, an id is already an
     equality-comparable proxy for "the exact same env value". *)
let contains_capability (v : value) : bool =
  let visited_frames : frame list ref = ref [] in
  let visited_envs : (int, unit) Hashtbl.t = Hashtbl.create 16 in
  let rec go (v : value) : bool =
    match v with
    | VCapability _ -> true
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated result -> go result
         | Unevaluated | Evaluating -> false)
    | VPair (a, b) -> go a || go b
    | VVector vs -> Array.exists go vs
    | VMap kvs -> List.exists (fun (k, v) -> go k || go v) kvs
    | VSet vs -> List.exists go vs
    | VClosure { env; vm_bc; vm_frames; _ } ->
        if vm_bc == dummy_bytecode then
          go_env !env
        else
          List.exists go_frame vm_frames
    | VEnvMap bindings -> List.exists (fun (_, v) -> go v) bindings
    | VNil | VBool _ | VInt _ | VFloat _ | VString _ | VKeyword _
    | VSymbol _ | VBuiltin _ | VBytecode _ -> false
  and go_env (e : env) : bool =
    if Hashtbl.mem visited_envs e.env_id then false
    else begin
      Hashtbl.add visited_envs e.env_id ();
      List.exists (fun (_, v) -> go v) e.bindings
    end
  and go_frame (fr : frame) : bool =
    if List.memq fr !visited_frames then false
    else begin
      visited_frames := fr :: !visited_frames;
      let live = Array.sub fr.slots 0 fr.len in
      Array.exists go live
    end
  in
  go v

(* ---- Free-variable analysis (for the LAW 20 node key) ----
   The set of symbols a node's code references but does not itself bind. The
   persistent node key resolves exactly these to their *value* hashes, so a node
   depends on the definitions it actually uses — not on the whole ambient
   environment (rebinding an unrelated global must not re-key it). Over-approx is
   sound (fewer hits); under-approx is not, so binding forms are handled
   conservatively. *)
module SS = Set.Make(String)

let free_vars (e : expr) : SS.t =
  let add_all names b = List.fold_left (fun acc n -> SS.add n acc) b names in
  (* names a `do`/`module` block binds for its siblings (defs, incl. located) *)
  let block_binders exprs =
    List.filter_map (function
      | EDef (n, _, _) | EDefNode (n, _, _) | EDefValue (n, _) -> Some n
      | ELocated (_, (EDef (n, _, _) | EDefNode (n, _, _) | EDefValue (n, _))) -> Some n
      | _ -> None) exprs
  in
  let rec fv bound e =
    match e with
    | ELiteral _ | EQuote _ | ELoad _ | ELoadModule _ | EIsland _ -> SS.empty
    | ESymbol s -> if SS.mem s bound then SS.empty else SS.singleton s
    | EIf (c, t, f) -> SS.union (fv bound c) (SS.union (fv bound t) (fv bound f))
    | ELet (binds, body) | ELetStar (binds, body) ->
        let bound' = add_all (List.map fst binds) bound in
        let rhs = List.fold_left (fun a (_, e) -> SS.union a (fv bound' e)) SS.empty binds in
        SS.union rhs (fv bound' body)
    | EFn (params, body) -> fv (add_all params bound) body
    | EApply (f, args) ->
        List.fold_left (fun a e -> SS.union a (fv bound e)) (fv bound f) args
    | EForce e | EDelay e | ENode e -> fv bound e
    | EWithCaps (caps, body) -> SS.union (fv bound caps) (fv bound body)
    | EPerform (_, args) ->
        List.fold_left (fun a e -> SS.union a (fv bound e)) SS.empty args
    | EWithHandler (handlers, body) ->
        let hs = List.fold_left (fun a (_, e) -> SS.union a (fv bound e)) SS.empty handlers in
        SS.union hs (fv bound body)
    | EDef (name, params, body) | EDefNode (name, params, body) ->
        fv (add_all params (SS.add name bound)) body
    | EDefValue (_, e) ->
        (* Whole-block letrec* scope is handled by block_binders; a
           self-reference in the RHS is a referenced-before-definition error
           at runtime, never a dependency on an outer binding. *)
        fv bound e
    | EDo exprs | EModule exprs ->
        let bound' = add_all (block_binders exprs) bound in
        List.fold_left (fun a e -> SS.union a (fv bound' e)) SS.empty exprs
    | EImport mod_expr -> fv bound mod_expr
    | EWithConfig (m, body) -> SS.union (fv bound m) (fv bound body)
    | EConfig (k, d) ->
        SS.union (fv bound k) (match d with Some e -> fv bound e | None -> SS.empty)
    | ETyped (e, _) -> fv bound e
    | ELocated (_, e) -> fv bound e
  in
  fv SS.empty e


(* =================================================================== *)
(*  Environment access and extension                                    *)
(* =================================================================== *)

(* Incremental hash: hash("env", parent_hash, binding_name, hash_of_value).
   O(1) in the size of the env chain. *)
let env_extend_hash (parent_hash : string) (name : string) (v_hash : string) : string =
  hash_string (String.concat ":" ["env"; parent_hash; name; v_hash])

(* Extend an environment with one binding.
   Creates a new env node with a fresh ID and an incrementally-computed hash. *)
let extend_env (env : env) (name : string) (v : value) : env =
  let v_hash = hash_value v in
  { env_id = fresh_env_id ();
    env_hash = env_extend_hash env.env_hash name v_hash;
    bindings = (name, v) :: env.bindings }

(* Compute the hash of a flat list of bindings (sorted for determinism).
   Used for initial environments where we don't have a parent. *)
let hash_bindings_flat (bindings : (string * value) list) : string =
  let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b) bindings in
  let parts = List.map (fun (name, v) ->
    String.concat ":" ["env_binding"; name; hash_value v]
  ) sorted in
  hash_string (String.concat ":" ("env_flat" :: parts))

(* Build an environment from a flat list of bindings (for initial env).
   Assigns a fresh ID and computes a deterministic hash. *)
let env_of_bindings (bindings : (string * value) list) : env =
  { env_id = fresh_env_id ();
    env_hash = hash_bindings_flat bindings;
    bindings }


(* =================================================================== *)
(*  Lookup and multi-extension                                          *)
(* =================================================================== *)

let rec lookup_env (env : env) (name : string) : value option =
  let rec walk = function
    | [] -> None
    | (n, v) :: rest -> if n = name then Some v else walk rest
  in
  walk env.bindings

let extend_env_many (env : env) (bindings : (string * value) list) : env =
  List.fold_left (fun e (n, v) -> extend_env e n v) env bindings


(* =================================================================== *)
(*  Constructor helpers                                                 *)
(* =================================================================== *)


let make_closure ?(name=None) params body env_ref =
  VClosure { fn_name = name; params; body; env = env_ref; vm_bc = dummy_bytecode; vm_offset = 0; vm_frames = [] }

let make_thunk ?vm_code:(vc=None) ?type_ann:(ta=None) ?thunk_loc:(tl=None) ?config_hash:(ch="") expr env =
  VThunk { thunk_status = Unevaluated; thunk_hash = None; thunk_expr = expr; thunk_env = env; vm_code = vc; type_ann = ta; thunk_loc = tl; config_hash = ch; thunk_persist = false; node_fv = []; node_caps = [] }

(* ---- Frame helpers ---- *)

let make_frame n = { slots = Array.make n VNil; len = n }

let frame_get f i =
  if i < f.len then f.slots.(i) else VNil

let frame_set f i v =
  if i >= Array.length f.slots then begin
    let ncap = max (Array.length f.slots * 2) (i + 1) in
    let a = Array.make ncap VNil in
    Array.blit f.slots 0 a 0 f.len;
    f.slots <- a
  end;
  if i >= f.len then f.len <- i + 1;
  f.slots.(i) <- v

(* ---- Quotation: expr -> value ---- *)

let rec quote_to_value (e : expr) : value =
  match e with
  | ELiteral v -> v
  | ESymbol s -> VSymbol s
  | EIf (cond, then_e, else_e) ->
      VPair (VSymbol "if",
        VPair (quote_to_value cond,
          VPair (quote_to_value then_e,
            VPair (quote_to_value else_e, VNil))))
  | ELet (bindings, body) ->
      let qbindings = List.fold_right (fun (n, e) acc ->
        VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)
      ) bindings VNil in
      VPair (VSymbol "let",
        VPair (qbindings,
          VPair (quote_to_value body, VNil)))
  | EFn (params, body) ->
      VPair (VSymbol "fn",
        VPair (VVector (Array.of_list (List.map (fun p -> VSymbol p) params)),
          VPair (quote_to_value body, VNil)))
  | EApply (fn, args) ->
      let qfn = quote_to_value fn in
      let qargs = List.map quote_to_value args in
      let args_list = List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil in
      VPair (qfn, args_list)
  | EQuote e -> VPair (VSymbol "quote", VPair (quote_to_value e, VNil))
  | EForce e -> VPair (VSymbol "force", VPair (quote_to_value e, VNil))
  | EDelay e -> VPair (VSymbol "delay", VPair (quote_to_value e, VNil))
  | ENode e -> VPair (VSymbol "node", VPair (quote_to_value e, VNil))
  | EDefNode (name, params, body) ->
      VPair (VSymbol "defnode",
        VPair (VSymbol name,
          VPair (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil,
            VPair (quote_to_value body, VNil))))
  | EDo exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "do", List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EDef (name, params, body) ->
      VPair (VSymbol "def",
        VPair (VSymbol name,
          VPair (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil,
            VPair (quote_to_value body, VNil))))
  | EDefValue (name, e) ->
      VPair (VSymbol "def",
        VPair (VSymbol name, VPair (quote_to_value e, VNil)))
  | ELetStar (bindings, body) ->
      VPair (VSymbol "let*",
        VPair (List.fold_right (fun (n, e) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)) bindings VNil,
          VPair (quote_to_value body, VNil)))
  | EWithCaps (caps, body) ->
      VPair (VSymbol "with-caps", VPair (quote_to_value caps, VPair (quote_to_value body, VNil)))
  | EPerform (name, args) ->
      let qargs = List.map quote_to_value args in
      VPair (VSymbol "perform",
        VPair (VSymbol name, List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil))
  | EWithHandler (handlers, body) ->
      VPair (VSymbol "with-handler",
        VPair (List.fold_right (fun (n, h) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value h, VNil)), acc)) handlers VNil,
          VPair (quote_to_value body, VNil)))
  | EModule exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "module",
        List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EImport mod_expr ->
      VPair (VSymbol "import", VPair (quote_to_value mod_expr, VNil))
  | ELoad path ->
      VPair (VSymbol "load", VPair (VString path, VNil))
  | ELoadModule path ->
      VPair (VSymbol "load-module", VPair (VString path, VNil))
  | EIsland (uri, pin) ->
      let pin_v = match pin with Some p -> VString p | None -> VNil in
      VPair (VSymbol "island",
        VPair (VString uri, VPair (pin_v, VNil)))
  | EWithConfig (map_expr, body) ->
      VPair (VSymbol "with-config",
        VPair (quote_to_value map_expr, VPair (quote_to_value body, VNil)))
  | EConfig (key_expr, default) ->
      let default_v = match default with Some d -> quote_to_value d | None -> VNil in
      VPair (VSymbol "config",
        VPair (quote_to_value key_expr, VPair (default_v, VNil)))
  | ETyped (e, ty) ->
      VPair (VSymbol ":",
        VPair (quote_to_value e, VPair (quote_to_value ty, VNil)))
  | ELocated (_, e) ->
      quote_to_value e

(* =================================================================== *)
(*  Pretty-print a value for the REPL                                   *)
(* =================================================================== *)

let rec string_of_value (v : value) : string =
  match v with
  | VNil -> "nil"
  | VBool true -> "true"
  | VBool false -> "false"
  | VInt n -> string_of_int n
  | VFloat f -> string_of_float f
  | VString s -> "\"" ^ String.escaped s ^ "\""
  | VKeyword k -> ":" ^ k
  | VSymbol s -> s
  | VPair (car, cdr) ->
      let rec list_string v =
        match v with
        | VPair (a, VNil) -> string_of_value a
        | VPair (a, d) -> string_of_value a ^ " " ^ list_string d
        | _ -> ". " ^ string_of_value v
      in
      "(" ^ list_string v ^ ")"
  | VVector vs ->
      "[" ^ String.concat " " (List.map string_of_value (Array.to_list vs)) ^ "]"
  | VMap kvs ->
      "{" ^ String.concat ", "
        (List.map (fun (k, v) -> string_of_value k ^ " " ^ string_of_value v) kvs) ^ "}"
  | VSet vs ->
      "#{" ^ String.concat " " (List.map string_of_value vs) ^ "}"
  | VClosure { fn_name = Some n; _ } -> "#<fn " ^ n ^ ">"
  | VClosure { fn_name = None; _ } -> "#<fn>"
  | VBuiltin (name, _) -> "#<builtin " ^ name ^ ">"
  | VCapability c -> string_of_capability c
  | VThunk t ->
      (match t.thunk_status with
       | Unevaluated -> "#<thunk>"
       | Evaluating -> "#<thunk: evaluating>"
       | Evaluated v -> "#<thunk: " ^ string_of_value v ^ ">")
  | VEnvMap bindings ->
      "#<envmap " ^ string_of_int (List.length bindings) ^ " exports>"
  | VBytecode bc ->
      "#<bytecode " ^ string_of_int (Array.length bc.code) ^ " ops>"

and string_of_capability (c : capability) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> ":ro" | Write -> ":wo" | ReadWrite -> ":rw" in
      "#<cap fs " ^ path ^ " " ^ m ^ ">"
  | CapNetwork { protocol } -> "#<cap net " ^ protocol ^ ">"
  | CapProcess -> "#<cap process>"
  | CapCompose caps -> "#<cap compose " ^ string_of_int (List.length caps) ^ ">"
  | CapRestrict { scope; mode; _ } ->
      let m = match mode with
        | None -> "" | Some Read -> " :ro" | Some Write -> " :wo" | Some ReadWrite -> " :rw" in
      "#<cap restrict " ^ scope ^ m ^ ">"
  | CapNone -> "#<cap none>"
