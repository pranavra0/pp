include Effects
open Types
open Effect

type _ Effect.t += Get_session : Session.t Effect.t

let capabilities () = Effect.perform Get_capabilities
let config () = Effect.perform Get_config
let domain () = Effect.perform Get_domain

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

let record_read cell_id observed_hash =
  ignore (Effect.perform (Record_read (cell_id, observed_hash)));
  if Effect.perform Get_observe_all then
    Session.add_observation (Effect.perform Get_session) (cell_id, observed_hash)

let observe_proc _ = None

let observe_probe name =
  Session.observe_probe (Effect.perform Get_session) name

let config_cell_id key = Cell.(to_string (Config key))
let handler_cell_id name = Cell.(to_string (Handler name))
let config_absent_hash = hash_string "config-cell:absent"
let builtin_handler_hash = hash_string "handler-cell:builtin"

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
  | Some value -> hash_value (Backend.r.force value)
  | None -> config_absent_hash

let observe_handler name =
  match Effect.perform (Lookup_handler name) with
  | Some (_, hash) -> hash
  | None -> builtin_handler_hash

let record_config_read key =
  record_read (config_cell_id key) (observe_config key)

let record_handler_observation name =
  record_read (handler_cell_id name) (observe_handler name)

let observe_domain_cell name sub =
  Session.observe_domain (Effect.perform Get_session) name sub

let with_top_level (session : Session.t) (invocation : Invocation.t) ~f x =
  try f x with
  | effect Get_session, k -> Effect.Deep.continue k session
  | effect Get_invocation, k -> Effect.Deep.continue k invocation
  | effect Get_capabilities, k ->
      Effect.Deep.continue k (Invocation.initial_capabilities invocation)
  | effect Get_config, k -> Effect.Deep.continue k []
  | effect Get_handlers, k -> Effect.Deep.continue k []
  | effect (Lookup_handler _), k -> Effect.Deep.continue k None
  | effect (Record_read _), k -> Effect.Deep.continue k ()
  | effect In_node, k -> Effect.Deep.continue k false
  | effect Current_sandbox, k -> Effect.Deep.continue k None
  | effect Get_domain, k -> Effect.Deep.continue k None
  | effect Get_observe_all, k -> Effect.Deep.continue k true
