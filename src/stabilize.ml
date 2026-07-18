(* Push scheduler: side-table (node_key → thunk) + dirty reset.
   The reverse-edge index (cell → node keys) lives in Trace_repository
   (build_reverse_index / dirty_keys_for). *)

open Core_model

(* Side-table: node_key → in-memory thunk. Populated by the force path
   (evaluator.ml force) on every node-key
   computation. Used by reset_dirty to mark only the dirty subset
   Unevaluated, leaving clean thunks Evaluated so they skip Cache_policy.lookup Cache_policy.default
   entirely — the push-scheduler optimization. *)
let register_node_key ~key ~thunk =
  Session.set_node_thunk (Effect.perform Dynamic_scope.Get_session) key thunk

(* Mark each dirty node's in-memory thunk Unevaluated so the next force
   goes through Cache_policy.lookup Cache_policy.default → miss → recompute. Nodes not in the side-table
   (not currently in memory) are skipped — they will be fresh thunks on
   re-execute and naturally go through Cache_policy.lookup Cache_policy.default (pull behavior). *)
let reset_dirty (dirty_keys : string list) : unit =
  List.iter (fun k ->
    match Session.find_node_thunk (Effect.perform Dynamic_scope.Get_session) k with
    | Some t -> t.thunk_status <- Unevaluated
    | None -> ()) dirty_keys
