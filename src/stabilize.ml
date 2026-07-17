(* Push scheduler: side-table (node_key → thunk) + dirty reset.
   The reverse-edge index (cell → node keys) lives in store.ml
   (build_reverse_index / dirty_keys_for). *)

open Types

(* Side-table: node_key → in-memory thunk. Populated by the force path
   (evaluator.ml force) on every node-key
   computation. Used by reset_dirty to mark only the dirty subset
   Unevaluated, leaving clean thunks Evaluated so they skip Store.hit
   entirely — the push-scheduler optimization. *)
let side_table : (string, Types.thunk) Hashtbl.t = Hashtbl.create 256

let register_node_key ~key ~thunk =
  Hashtbl.replace side_table key thunk

(* Mark each dirty node's in-memory thunk Unevaluated so the next force
   goes through Store.hit → miss → recompute. Nodes not in the side-table
   (not currently in memory) are skipped — they will be fresh thunks on
   re-execute and naturally go through Store.hit (pull behavior). *)
let reset_dirty (dirty_keys : string list) : unit =
  List.iter (fun k ->
    match Hashtbl.find_opt side_table k with
    | Some t -> t.thunk_status <- Unevaluated
    | None -> ()) dirty_keys

let clear_side_table () = Hashtbl.clear side_table
