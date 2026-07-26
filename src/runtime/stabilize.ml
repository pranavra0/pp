open Pp_kernel
(* Watch stabilization retains the in-memory identities needed to follow
   child-result cells across node re-keying. The durable reverse index remains
   cell → direct node readers; evaluated parents validate child edges on force. *)

open Core_model

(* Side-table: node_key → in-memory thunk. Populated by the force path
   (evaluator.ml force) on every node-key
   computation. Used by reset_dirty to mark only the dirty subset
   Unevaluated, leaving clean thunks Evaluated so they skip Cache_policy.lookup Cache_policy.default
   entirely — the push-scheduler optimization. *)
let register_node_key ~(key : Identity_types.Node_key.t) ~thunk =
  Session.set_node_thunk (Effect.perform Dynamic_scope.Get_session) key thunk

let add_runtime_edges reverse =
  Session.iter_node_dependents (Effect.perform Dynamic_scope.Get_session)
    (fun id keys ->
      let cell = Cell.serialize (Cell.Node id) in
      let stored = Option.value ~default:[] (Hashtbl.find_opt reverse cell) in
      let runtime = List.map Identity_types.Node_key.to_string keys in
      Hashtbl.replace reverse cell (List.sort_uniq compare (runtime @ stored)))

let dependency_cells key =
  let durable = Cell.serialize (Cell.Node key) in
  match Session.find_node_thunk
          (Effect.perform Dynamic_scope.Get_session)
          (Identity_types.Node_key.of_string key)
  with
  | Some { thunk_hash = Some id; _ } ->
      [durable; Cell.serialize (Cell.Node id)]
  | Some { thunk_hash = None; _ } | None -> [durable]

let reset_dirty (dirty_keys : Identity_types.Node_key.t list) : unit =
  List.iter (fun k ->
    match Session.find_node_thunk (Effect.perform Dynamic_scope.Get_session) k with
    | Some thunk -> thunk.thunk_status <- Unevaluated
    | None -> ()) dirty_keys

let evaluated_dependencies_changed
    ~(key : Identity_types.Node_key.t) ~(result : value) : bool =
  let cache_key = Identity_types.Cache_key.of_node_key key in
  let result_hash = Identity_types.Object_hash.of_digest (Identity.hash_value result) in
  let node_cell_matches (cell, expected) =
    match Cell.parse (Identity_types.Cell_id.to_string cell) with
    | Cell.Node _ ->
        (match Observation.observe_id cell with
         | Some current -> current = expected
         | None -> false)
    | _ -> true
  in
  let matching_traces =
    Trace_repository.load Trace_repository.default ~key:cache_key
    |> List.filter (fun trace ->
         trace.Trace_repository.outcome = Trace_repository.Ok
         && trace.Trace_repository.result_hash = result_hash)
  in
  matching_traces <> []
  && not (List.exists
    (fun trace -> List.for_all node_cell_matches trace.Trace_repository.reads)
    matching_traces)
