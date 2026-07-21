open Pp_kernel
(* Watch stabilization retains the in-memory identities needed to follow
   child-result cells across node re-keying. The durable reverse index remains
   cell → node keys; Store_index walks those edges transitively. *)

open Core_model

(* Side-table: node_key → in-memory thunk. Populated by the force path
   (evaluator.ml force) on every node-key
   computation. Used by reset_dirty to mark only the dirty subset
   Unevaluated, leaving clean thunks Evaluated so they skip Cache_policy.lookup Cache_policy.default
   entirely — the push-scheduler optimization. *)
let register_node_key ~(key : Identity_types.Node_key.t) ~thunk =
  Session.set_node_thunk (Effect.perform Dynamic_scope.Get_session) key thunk

let dependency_cell key =
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_node_thunk session (Identity_types.Node_key.of_string key) with
  | Some { thunk_hash = Some id; _ } -> Some (Cell.serialize (Cell.Node id))
  | Some { thunk_hash = None; _ } | None -> None

let add_runtime_edges reverse =
  Session.iter_node_dependents (Effect.perform Dynamic_scope.Get_session)
    (fun id keys ->
      let cell = Cell.serialize (Cell.Node id) in
      let stored = Option.value ~default:[] (Hashtbl.find_opt reverse cell) in
      let runtime = List.map Identity_types.Node_key.to_string keys in
      Hashtbl.replace reverse cell (List.sort_uniq compare (runtime @ stored)))

(* Mark each dirty node's in-memory thunk Unevaluated so the next force
   goes through Cache_policy.lookup Cache_policy.default → miss → recompute. Nodes not in the side-table
   (not currently in memory) are skipped — they will be fresh thunks on
   re-execute and naturally go through Cache_policy.lookup Cache_policy.default (pull behavior). *)
let reset_dirty (dirty_keys : Identity_types.Node_key.t list) : unit =
  List.iter (fun k ->
    match Session.find_node_thunk (Effect.perform Dynamic_scope.Get_session) k with
    | Some thunk -> thunk.thunk_status <- Unevaluated
    | None -> ()) dirty_keys
