open Core_model

(* Global counter for unique environment IDs *)
let env_counter = ref 0
let fresh_env_id () =
  let id = !env_counter in
  env_counter := id + 1;
  id

(* Empty environment — root of all environment chains *)
let empty =
  { env_id = fresh_env_id ();
    env_hash = Digest.string "env:empty";
    bindings = [] }
let env_extend_hash (parent_hash : string) (name : string) (v_hash : string) : string =
  Hasher.hash_concat ["env"; parent_hash; name; v_hash]

(* Extend an environment with one binding.
   Creates a new env node with a fresh ID and an incrementally-computed hash. *)
let extend (env : env) (name : string) (v : value) : env =
  let v_hash = Identity.hash_value v in
  { env_id = fresh_env_id ();
    env_hash = env_extend_hash env.env_hash name v_hash;
    bindings = (name, v) :: env.bindings }

(* Compute the hash of a flat list of bindings (sorted for determinism).
   Used for initial environments where we don't have a parent. *)
let hash_bindings_flat (bindings : (string * value) list) : string =
  let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b) bindings in
  let parts = List.map (fun (name, v) ->
    Hasher.hash_concat ["env_binding"; name; Identity.hash_value v]
  ) sorted in
  Hasher.hash_concat ("env_flat" :: parts)

(* Build an environment from a flat list of bindings (for initial env).
   Assigns a fresh ID and computes a deterministic hash. *)
let of_bindings (bindings : (string * value) list) : env =
  { env_id = fresh_env_id ();
    env_hash = hash_bindings_flat bindings;
    bindings }


let lookup (env : env) (name : string) : value option =
  let rec walk = function
    | [] -> None
    | (n, v) :: rest -> if n = name then Some v else walk rest
  in
  walk env.bindings

let make_closure ?(name=None) params body env_ref =
  VClosure { fn_name = name; params; body; env = env_ref }

let make_thunk ?type_ann:(ta=None) ?thunk_loc:(tl=None) ?thunk_name:(tn=None)
    ?config_hash:(ch="") expr env =
  VThunk { thunk_status = Unevaluated; thunk_hash = None; thunk_expr = expr;
           thunk_env = env; thunk_name = tn; type_ann = ta; thunk_loc = tl;
           config_hash = ch; thunk_persist = false; node_caps = [] }
