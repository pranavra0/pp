open Pp_kernel
include Effects
open Core_model
open Effect

type _ Effect.t += Get_session : Session.t Effect.t

type handler = string * (value list -> value) * string

let tail_capabilities : Capability.t list list ref = ref []
let tail_configs : value list ref = ref []
let tail_handlers : handler list list ref = ref []
let tail_capability_depth_ref = ref 0

let capabilities () = Effect.perform Get_capabilities
let config () = Effect.perform Get_config
let domain () = Effect.perform Get_domain

let with_tail_scope ?depth stack item f =
  stack := item :: !stack;
  Option.iter incr depth;
  let closed = ref false in
  let leave () =
    if not !closed then begin
      closed := true;
      stack := List.tl !stack;
      Option.iter (fun depth -> decr depth) depth
    end
  in
  try
    let result = f leave in
    leave ();
    result
  with exn ->
    leave ();
    raise exn

let with_tail_capabilities capabilities f =
  with_tail_scope ~depth:tail_capability_depth_ref tail_capabilities capabilities f

let with_tail_config frame f =
  with_tail_scope tail_configs frame f

let with_tail_handlers handlers f =
  with_tail_scope tail_handlers handlers f

let tail_capabilities_at depth =
  if !tail_capability_depth_ref > depth then
    match !tail_capabilities with
    | capabilities :: _ -> Some capabilities
    | [] -> None
  else None
let tail_capability_depth () = !tail_capability_depth_ref

let with_capabilities (capabilities : Capability.t list) f =
  try f () with
  | effect Get_capabilities, k -> Effect.Deep.continue k capabilities

let with_config (frame : value) f =
  try f () with
  | effect Get_config, k -> Effect.Deep.continue k (frame :: config ())

let with_handlers
    (handlers : (string * (value list -> value) * string) list) f =
  let identities = List.map (fun (name, _, hash) -> name, hash) handlers in
  try f () with
  | effect (Lookup_handler name), k ->
      (match List.find_opt (fun (candidate, _, _) -> candidate = name) handlers with
       | Some (_, handler, hash) -> Effect.Deep.continue k (Some (handler, hash))
       | None -> Effect.Deep.continue k (Effect.perform (Lookup_handler name)))
  | effect Get_handlers, k ->
      Effect.Deep.continue k (identities @ Effect.perform Get_handlers)

let with_domain (name : string) f =
  try f () with
  | effect Get_domain, k -> Effect.Deep.continue k (Some name)

let without_observation_collection f =
  try f () with
  | effect Get_observe_all, k -> Effect.Deep.continue k false

let require_script_tier message =
  if Effect.perform In_node then failwith message

let record_read cell_id observed_hash =
  ignore (Effect.perform (Record_read (cell_id, observed_hash)));
  if Effect.perform Get_observe_all then
    Session.add_observation (Effect.perform Get_session) (cell_id, observed_hash)

let record_event event =
  Session.add_event (Effect.perform Get_session) event

let config_absent_hash = Hasher.hash_string "config-cell:absent"
let builtin_handler_hash = Hasher.hash_string "handler-cell:builtin"

let config_lookup key =
  let rec find = function
    | [] -> None
    | VMap bindings :: rest ->
        (match List.assoc_opt (VString key) bindings with
         | Some value -> Some value
         | None ->
             (match List.assoc_opt (VKeyword key) bindings with
              | Some value -> Some value
              | None -> find rest))
    | _ :: rest -> find rest
  in
  find (config ())

let observe_config key =
  match config_lookup key with
  | Some value ->
      Identity.hash_value (Session.force (Effect.perform Get_session) value)
  | None -> config_absent_hash

let observe_handler name =
  match Effect.perform (Lookup_handler name) with
  | Some (_, hash) -> hash
  | None -> builtin_handler_hash

let tail_handler_identities () =
  List.concat_map
    (fun handlers -> List.map (fun (name, _, hash) -> name, hash) handlers)
    !tail_handlers

let tail_lookup_handler name =
  let rec find = function
    | [] -> None
    | handlers :: rest ->
        (match List.find_opt (fun (candidate, _, _) -> candidate = name) handlers with
         | Some (_, handler, hash) -> Some (handler, hash)
         | None -> find rest)
  in
  find !tail_handlers

let with_top_level (session : Session.t) (invocation : Invocation.t) ~f x =
  let saved_capabilities = !tail_capabilities in
  let saved_configs = !tail_configs in
  let saved_handlers = !tail_handlers in
  let saved_capability_depth = !tail_capability_depth_ref in
  tail_capabilities := [];
  tail_configs := [];
  tail_handlers := [];
  tail_capability_depth_ref := 0;
  Fun.protect
    (fun () ->
      try f x with
      | effect Get_session, k -> Effect.Deep.continue k session
      | effect Get_invocation, k -> Effect.Deep.continue k invocation
      | effect Get_capabilities, k ->
          let capabilities =
            match !tail_capabilities with
            | capabilities :: _ -> capabilities
            | [] -> Invocation.initial_capabilities invocation
          in
          Effect.Deep.continue k capabilities
      | effect Get_config, k -> Effect.Deep.continue k !tail_configs
      | effect Get_handlers, k ->
          Effect.Deep.continue k (tail_handler_identities ())
      | effect (Lookup_handler name), k ->
          Effect.Deep.continue k (tail_lookup_handler name)
      | effect (Record_read _), k -> Effect.Deep.continue k ()
      | effect (Record_event event), k ->
          Session.add_event session event;
          Effect.Deep.continue k ()
      | effect (Record_node_force id), k ->
          Option.iter (Session.add_wanted_node session)
            (Session.node_key_by_id session id);
          Effect.Deep.continue k ()
      | effect In_node, k -> Effect.Deep.continue k false
      | effect Current_sandbox, k -> Effect.Deep.continue k None
      | effect Get_domain, k -> Effect.Deep.continue k None
      | effect Get_observe_all, k -> Effect.Deep.continue k true)
    ~finally:(fun () ->
      tail_capabilities := saved_capabilities;
      tail_configs := saved_configs;
      tail_handlers := saved_handlers;
      tail_capability_depth_ref := saved_capability_depth)
