open Core_model

(* Captured environments can cycle; env ids bound the walk. Unevaluated thunks
   remain unforced. *)
let contains_value_kind (is_target : value -> bool) (v : value) : bool =
  let visited_envs : (int, unit) Hashtbl.t = Hashtbl.create 16 in
  let rec go (v : value) : bool =
    if is_target v then true
    else match v with
    | VCapability _ | VSealed _ -> false  (* not the target kind; already false above *)
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated result -> go result
         | Unevaluated | Evaluating -> false)
    | VPair (a, b) -> go a || go b
    | VVector vs -> Array.exists go vs
    | VMap kvs -> List.exists (fun (k, v) -> go k || go v) kvs
    | VSet vs -> List.exists go vs
    | VClosure { env; _ } ->
        go_env !env
    | VEnvMap bindings -> List.exists (fun (_, v) -> go v) bindings
    | VNil | VBool _ | VInt _ | VFloat _ | VString _ | VKeyword _
    | VSymbol _ | VBuiltin _ -> false
  and go_env (e : env) : bool =
    if Hashtbl.mem visited_envs e.env_id then false
    else begin
      Hashtbl.add visited_envs e.env_id ();
      List.exists (fun (_, v) -> go v) e.bindings
    end
  in
  go v

(* The two ban predicates share the walk above; only the leaf test differs.
   [contains_authority]: does [v] contain a capability OR a sealed value
   (either bans a node boundary crossing). [contains_sealed]: does [v]
   specifically contain a sealed value — used only to word the error message
   precisely ("... may not be or contain a sealed value" vs "... a
   capability") when [contains_authority] already said yes. *)
let contains_authority (v : value) : bool =
  contains_value_kind (function VCapability _ | VSealed _ -> true | _ -> false) v

let contains_sealed (v : value) : bool =
  contains_value_kind (function VSealed _ -> true | _ -> false) v

(* A closure captures an environment frame, but only the names referenced by
   its body are inputs to the closure. This keeps a later ambient binding from
   looking like authority captured by an earlier helper function while still
   rejecting a closure whose body really reaches a capability. *)
let contains_authority_in_referenced_values (v : value) : bool =
  let visited_envs : (int, unit) Hashtbl.t = Hashtbl.create 16 in
  let rec go = function
    | VCapability _ | VSealed _ -> true
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated result -> go result
         | Unevaluated | Evaluating -> false)
    | VPair (a, b) -> go a || go b
    | VVector vs -> Array.exists go vs
    | VMap kvs -> List.exists (fun (k, v) -> go k || go v) kvs
    | VSet vs -> List.exists go vs
    | VClosure { body; env; _ } ->
        let e = !env in
        if Hashtbl.mem visited_envs e.env_id then false
        else begin
          Hashtbl.add visited_envs e.env_id ();
          List.exists (fun name ->
            match Environment.lookup e name with
            | Some value -> go value
            | None -> false)
            (Free_vars.SS.elements (Free_vars.free_vars body))
        end
    | VEnvMap bindings -> List.exists (fun (_, value) -> go value) bindings
    | VNil | VBool _ | VInt _ | VFloat _ | VString _ | VKeyword _
    | VSymbol _ | VBuiltin _ -> false
  in
  go v
