open Pp_kernel
open Core_model

let replay_reads = Node.replay_node_reads

let apply ~force ~fn_name ~params ~body ~closure_env args k =
  let args = List.map force args in
  let env = List.fold_left2 (fun env param arg ->
    Environment.extend env param arg
  ) !closure_env params args in
  k (Evaluator_thunks.make_node ?name:fn_name body env ~arguments:args)

let force ~key ~run thunk =
  let captured_caps = match thunk.thunk_kind with
    | Persistent { captured_caps; _ } -> captured_caps
    | Ephemeral -> []
  in
  Node.force ~key ~authorized:(Observation.authorized_id captured_caps) ~run thunk
