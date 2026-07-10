(* pp types — mutually recursive type definitions for the pp runtime *)

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
  | EEffect of expr * expr  (* (effect caps-expr body) — effectful block *)
  | EPerform of string * expr list  (* (perform effect-name args...) *)
  | EWithHandler of (string * expr) list * expr  (* effect handler installation *)
  | EDelay of expr          (* explicit delay *)
  | ENode of expr           (* (node body) — persistent cacheable node *)
  | EDefNode of string * string list * expr  (* (defnode (name params...) body...) *)
  | EDo of expr list        (* sequencing — forces each, returns last *)
  | EDef of string * string list * expr  (* (def name (params...) body) *)
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
  | CapRestrict of { cap : capability; scope : string }
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
  | MAKE_CLOSURE of int * int(* code offset, nparams *)
  | CALL of int | TAIL_CALL of int | RETURN | HALT
  | BUILTIN of int           (* cp idx of name; pushes the VBuiltin value *)
  | CONS                     (* pop b, pop a, push VPair(a,b) *)
  | ENTER_EFFECT | EXIT_EFFECT
  | PERFORM of int * int     (* cp idx of effect name, nargs *)
  | PUSH_HANDLER of int      (* n (name,closure) pairs already on stack *)
  | POP_HANDLER
  | MAKE_MODULE of int       (* nexports; pops name+thunk pairs, pushes VEnvMap *)
  | IMPORT                   (* pop VEnvMap, merge bindings into current frame *)
  | LOAD_FILE of int | LOAD_MODULE_FILE of int  (* cp idx of path *)
  | NOP
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
  | EEffect (caps, body) ->
      hash_concat ["effect"; hash_expr caps; hash_expr body]
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
  let rec hash_val v =
    match v with
    | VThunk t ->
        (match t.thunk_hash with
         | Some h -> h  (* O(1): use precomputed content-addressable hash *)
         | None ->
             (* Should not happen in practice — all thunks go through make_thunk_ca.
                Fall back to structural hash using the env's cached hash. *)
             hash_concat ["thunk"; hash_expr t.thunk_expr; t.thunk_env.env_hash; t.config_hash])
    | VNil -> hash_string "nil"
    | VBool true -> hash_string "bool:true"
    | VBool false -> hash_string "bool:false"
    | VInt n -> hash_concat ["int"; string_of_int n]
    | VFloat f -> hash_concat ["float"; string_of_float f]
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
    | VClosure { fn_name; params; body; env = _; _ } ->
        let name_part = match fn_name with Some n -> n | None -> "anon" in
        hash_concat ["closure"; name_part;
                     hash_concat ("params" :: params);
                     hash_expr body]
        (* Env deliberately NOT hashed — closures hold a ref to mutable global env *)
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
  | CapRestrict { cap; scope } ->
      hash_concat ["cap_restrict"; hash_capability cap; scope]
  | CapNone -> hash_string "cap_none"


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


(* Dummy bytecode for tree-walker closures *)
let dummy_bytecode = { consts = [||]; code = [||]; nparams_of = Hashtbl.create 0; param_names_of = Hashtbl.create 0; closure_names_of = Hashtbl.create 0 }

let make_closure ?(name=None) params body env_ref =
  VClosure { fn_name = name; params; body; env = env_ref; vm_bc = dummy_bytecode; vm_offset = 0; vm_frames = [] }

let make_thunk ?vm_code:(vc=None) ?type_ann:(ta=None) ?thunk_loc:(tl=None) ?config_hash:(ch="") expr env =
  VThunk { thunk_status = Unevaluated; thunk_hash = None; thunk_expr = expr; thunk_env = env; vm_code = vc; type_ann = ta; thunk_loc = tl; config_hash = ch; thunk_persist = false }

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
        VPair (list_to_list_v qbindings,
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
          VPair (list_to_list_v (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil),
            VPair (quote_to_value body, VNil))))
  | EDo exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "do", List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EDef (name, params, body) ->
      VPair (VSymbol "def",
        VPair (VSymbol name,
          VPair (list_to_list_v (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil),
            VPair (quote_to_value body, VNil))))
  | ELetStar (bindings, body) ->
      VPair (VSymbol "let*",
        VPair (list_to_list_v (List.fold_right (fun (n, e) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)) bindings VNil),
          VPair (quote_to_value body, VNil)))
  | EEffect (caps, body) ->
      VPair (VSymbol "effect", VPair (quote_to_value caps, VPair (quote_to_value body, VNil)))
  | EPerform (name, args) ->
      let qargs = List.map quote_to_value args in
      VPair (VSymbol "perform",
        VPair (VSymbol name, list_to_list_v (List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil)))
  | EWithHandler (handlers, body) ->
      VPair (VSymbol "with-handler",
        VPair (list_to_list_v (List.fold_right (fun (n, h) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value h, VNil)), acc)) handlers VNil),
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
  | ELocated ((file, line), e) ->
      quote_to_value e

and list_to_list_v (v : value) : value = v  (* identity *)


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
  | CapRestrict { scope; _ } -> "#<cap restrict " ^ scope ^ ">"
  | CapNone -> "#<cap none>"
