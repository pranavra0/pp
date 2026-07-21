open Pp_kernel
(* Deep forcing owns both the structural walk and scheduler fan-out. The
   builtin catalog only registers the language operation that calls this
   module; application orchestration does not leak into builtin definitions. *)

open Core_model

let rec force_deep_plain ~force (v : value) : value =
  match force v with
  | VPair (a, d) -> VPair (force_deep_plain ~force a, force_deep_plain ~force d)
  | VVector vs -> VVector (Array.map (force_deep_plain ~force) vs)
  | VMap kvs -> VMap (List.map (fun (k, v) -> (force_deep_plain ~force k, force_deep_plain ~force v)) kvs)
  | VSet vs -> VSet (List.map (force_deep_plain ~force) vs)
  | other -> other

let find_kv ~force (kvs : (value * value) list) (key : string) : value option =
  List.find_map (fun (k, v) ->
    match Presentation.string_like k with
    | Some k' when k' = key -> Some (force v)
    | _ -> None)
    kvs

let collect_unevaluated_nodes (v : value) : Scheduler.job list =
  let seen_keys : (Identity_types.Node_key.t, unit) Hashtbl.t = Hashtbl.create 64 in
  let seen_pairs : value list ref = ref [] in
  let jobs = ref [] in
  let session = Effect.perform Dynamic_scope.Get_session in
  let scheduler = Session.scheduler session in
  let node = Session.node_operations session in
  let core = Session.core_operations session in
  let race_width () =
    match Scheduler.policy scheduler with Scheduler.Race n -> n | _ -> 1
  in
  let job_run (t : thunk) (key : Identity_types.Node_key.t) () : value =
    node.run_body ~key ~run:(fun () -> core.eval t.thunk_expr t.thunk_env) t
  in
  let rec walk = function
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated result -> walk result
         | Evaluating -> ()
         | Unevaluated when (match t.thunk_kind with Persistent _ -> true | Ephemeral -> false) ->
             let key = node.key_of t in
             if not (Hashtbl.mem seen_keys key) then begin
               Hashtbl.add seen_keys key ();
               if not (node.resolve_hit t key) then
                 jobs := { Scheduler.j_key = key; j_run = job_run t key;
                           j_width = race_width (); j_thunk = t } :: !jobs
             end
         | Unevaluated -> ())
    | VPair _ as pair ->
        if not (List.memq pair !seen_pairs) then begin
          seen_pairs := pair :: !seen_pairs;
          match pair with VPair (car, cdr) -> walk car; walk cdr | _ -> ()
        end
    | VVector values -> Array.iter walk values
    | VMap bindings -> List.iter (fun (key, value) -> walk key; walk value) bindings
    | VSet values -> List.iter walk values
    | _ -> ()
  in
  walk v;
  List.rev !jobs

let force_deep (v : value) : value =
  let session = Effect.perform Dynamic_scope.Get_session in
  let scheduler = Session.scheduler session in
  (match Scheduler.policy scheduler with
   | Scheduler.Serial -> ()
   | Scheduler.Parallel _ | Scheduler.Race _ | Scheduler.Remote _ ->
       (match collect_unevaluated_nodes v with
        | [] -> ()
        | jobs -> Scheduler.dispatch_batch scheduler jobs));
  force_deep_plain ~force:(Session.force session) v
