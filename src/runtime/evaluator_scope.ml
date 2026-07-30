open Pp_kernel
open Core_model
open Source_error

type operations = {
  eval : expr -> env -> value;
  eval_tail : expr -> env -> (value -> value) -> value;
  force : value -> value;
  apply : value -> value list -> env -> value;
}

type _ Effect.t += Leave_scope : value -> value Effect.t

let run_scope enter operations body env k =
  try
    enter (fun () ->
      operations.eval_tail body env
        (fun value -> Effect.perform (Leave_scope value)))
  with
  | effect (Leave_scope value), _ -> k value

let with_caps operations cap_expr body env k =
  let requested =
    match operations.force (operations.eval cap_expr env) with
    | VCapability capability -> capability
    | _ -> failwith "with-caps expects a capability value"
  in
  if not (Capability.subseteq requested (Dynamic_scope.capabilities ())) then
    capability Capability.err_with_caps_widen;
  run_scope (Dynamic_scope.with_capabilities [requested])
    operations body env k

let with_handlers operations handlers body env k =
  let handlers = List.map (fun (name, handler_expr) ->
    let handler = operations.force (operations.eval handler_expr env) in
    (name,
     (fun args -> operations.apply handler args env),
     Identity.hash_value handler)
  ) handlers in
  run_scope (Dynamic_scope.with_handlers handlers)
    operations body env k

let with_config operations map_expr body env k =
  let config = operations.force (operations.eval map_expr env) in
  match config with
  | VMap _ ->
      run_scope (Dynamic_scope.with_config config)
        operations body env k
  | _ -> failwith "with-config expects a map"

