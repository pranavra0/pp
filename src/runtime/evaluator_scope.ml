open Pp_kernel
open Core_model
open Source_error

type operations = {
  eval : expr -> env -> value;
  eval_tail : expr -> env -> (value -> value) -> value;
  force : value -> value;
  apply : value -> value list -> env -> value;
}

let with_caps operations cap_expr body env k =
  let requested =
    match operations.force (operations.eval cap_expr env) with
    | VCapability capability -> capability
    | _ -> failwith "with-caps expects a capability value"
  in
  if not (Capability.subseteq requested (Dynamic_scope.capabilities ())) then
    capability Capability.err_with_caps_widen;
  Dynamic_scope.with_tail_capabilities [requested]
    (fun leave -> operations.eval_tail body env (fun value ->
       leave ();
       k value))

let with_handlers operations handlers body env k =
  let handlers = List.map (fun (name, handler_expr) ->
    let handler = operations.force (operations.eval handler_expr env) in
    (name,
     (fun args -> operations.apply handler args env),
     Identity.hash_value handler)
  ) handlers in
  Dynamic_scope.with_tail_handlers handlers
    (fun leave -> operations.eval_tail body env (fun value ->
       leave ();
       k value))

let with_config operations map_expr body env k =
  let config = operations.force (operations.eval map_expr env) in
  match config with
  | VMap _ ->
      Dynamic_scope.with_tail_config config
        (fun leave -> operations.eval_tail body env (fun value ->
           leave ();
           k value))
  | _ -> failwith "with-config expects a map"

let read_config operations key_name default env k =
  Observation.record_config key_name;
  match Dynamic_scope.config_lookup key_name with
  | Some value -> k value
  | None ->
      (match default with
       | Some default -> operations.eval_tail default env k
       | None -> k VNil)
