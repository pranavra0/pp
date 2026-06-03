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
  | EDo of expr list        (* sequencing — forces each, returns last *)
  | EDef of string * string list * expr  (* (def name (params...) body) *)
  | EDefFexpr of string * string list * expr  (* (def-fexpr name (params...) body) *)
  | ELetStar of (string * expr) list * expr  (* sequential let — desugared by reader *)
  | EModule of expr list        (* (module body...) — thunk producing an env *)
  | EImport of expr             (* (import mod-expr) — force module, merge env *)
  | ELoad of string             (* (load "file.pp") — eval file in current env *)
  | ELoadModule of string       (* (load-module "file.pp") — eval file as module *)

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
  | VMacro of closure
  | VFexpr of fexpr
  | VEnvMap of (string * value) list  (* module export: list of (name, thunk) pairs *)

(* ---- Function closure ---- *)
and closure = {
  fn_name : string option;  (* optional name for debugging *)
  params : string list;
  body : expr;
  env : env ref;  (* reference to environment — sees later defs *)
}

(* ---- Fexpr — operative: receives unevaluated args + calling environment ---- *)
and fexpr = {
  fexpr_name : string option;
  fexpr_params : string list;
  fexpr_body : expr;
  fexpr_env : env ref;  (* reference to environment *)
}

(* ---- Thunk — a suspended computation ---- *)
and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;  (* precomputed content-addressable hash *)
  thunk_expr : expr;
  thunk_env : env;
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
  | CapTime of int       (* CPU time budget in ms *)
  | CapMemory of int     (* memory budget in bytes *)
  | CapCompose of capability list
  | CapRestrict of { cap : capability; scope : string }
  | CapNone

and fs_mode = Read | Write | ReadWrite


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

let hash_string (s : string) : string = Digest.string s

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
  | EDo exprs ->
      hash_concat ("do" :: List.map hash_expr exprs)
  | EDef (name, params, body) ->
      hash_concat ["def"; name; hash_concat ("params" :: params); hash_expr body]
  | EDefFexpr (name, params, body) ->
      hash_concat ["def_fexpr"; name; hash_concat ("params" :: params); hash_expr body]
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

and hash_value (v : value) : string =
  let rec hash_val v =
    match v with
    | VThunk t ->
        (match t.thunk_hash with
         | Some h -> h  (* O(1): use precomputed content-addressable hash *)
         | None ->
             (* Should not happen in practice — all thunks go through make_thunk_ca.
                Fall back to structural hash using the env's cached hash. *)
             hash_concat ["thunk"; hash_expr t.thunk_expr; t.thunk_env.env_hash])
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
    | VClosure { fn_name; params; body; env = _ } ->
        let name_part = match fn_name with Some n -> n | None -> "anon" in
        hash_concat ["closure"; name_part;
                     hash_concat ("params" :: params);
                     hash_expr body]
        (* Env deliberately NOT hashed — closures hold a ref to mutable global env *)
    | VBuiltin (name, _) ->
        hash_concat ["builtin"; name]
    | VCapability cap ->
        hash_capability cap
    | VMacro { params; body; env = _ } ->
        hash_concat ["macro"; hash_concat ("params" :: params);
                     hash_expr body]
    | VFexpr { fexpr_name; fexpr_params; fexpr_body; fexpr_env = _ } ->
        hash_concat ["fexpr";
                     (match fexpr_name with Some n -> n | None -> "anon");
                     hash_concat ("params" :: fexpr_params);
                     hash_expr fexpr_body]
        (* Env deliberately not hashed *)
    | VEnvMap bindings ->
        let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b) bindings in
        let parts = List.map (fun (name, v) ->
          hash_concat [name; hash_val v]
        ) sorted in
        hash_concat ("envmap" :: parts)
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
  | CapTime ms -> hash_concat ["cap_time"; string_of_int ms]
  | CapMemory bytes -> hash_concat ["cap_mem"; string_of_int bytes]
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
  Digest.string (String.concat ":" ["env"; parent_hash; name; v_hash])

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
  Digest.string (String.concat ":" ("env_flat" :: parts))

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
  VClosure { fn_name = name; params; body; env = env_ref }

let make_fexpr ?(name=None) params body env_ref =
  VFexpr { fexpr_name = name; fexpr_params = params; fexpr_body = body; fexpr_env = env_ref }

let make_thunk expr env =
  VThunk { thunk_status = Unevaluated; thunk_hash = None; thunk_expr = expr; thunk_env = env }


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
  | VMacro _ -> "#<macro>"
  | VFexpr { fexpr_name = Some n; _ } -> "#<fexpr " ^ n ^ ">"
  | VFexpr { fexpr_name = None; _ } -> "#<fexpr>"
  | VEnvMap bindings ->
      "#<envmap " ^ string_of_int (List.length bindings) ^ " exports>"

and string_of_capability (c : capability) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> ":ro" | Write -> ":wo" | ReadWrite -> ":rw" in
      "#<cap fs " ^ path ^ " " ^ m ^ ">"
  | CapNetwork { protocol } -> "#<cap net " ^ protocol ^ ">"
  | CapProcess -> "#<cap process>"
  | CapTime ms -> "#<cap time " ^ string_of_int ms ^ "ms>"
  | CapMemory bytes -> "#<cap memory " ^ string_of_int bytes ^ ">"
  | CapCompose caps -> "#<cap compose " ^ string_of_int (List.length caps) ^ ">"
  | CapRestrict { scope; _ } -> "#<cap restrict " ^ scope ^ ">"
  | CapNone -> "#<cap none>"
