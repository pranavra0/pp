open Pp_kernel
open Core_model

let apply ~force ~fn_name ~params ~body ~closure_env args k =
  let args = List.map force args in
  let env = List.fold_left2 (fun env param arg ->
    Environment.extend env param arg
  ) !closure_env params args in
  k (Evaluator_thunks.make_node ?name:fn_name body env ~arguments:args)

let force ~key ~run thunk =
  Node.force ~key
    ~authorized:(Observation.authorized_id
                   (Evaluator_thunks.captured_capabilities thunk))
    ~run thunk
