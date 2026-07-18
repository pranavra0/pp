type _ Effect.t +=
  | Get_session : Session.t Effect.t
  | Get_invocation : Invocation.t Effect.t
  | Get_capabilities : Capability.t list Effect.t
  | Get_config : Types.value list Effect.t
  | Get_handlers : (string * string) list Effect.t
  | Lookup_handler : string -> ((Types.value list -> Types.value) * string) option Effect.t
  | Record_read : string * string -> unit Effect.t
  | In_node : bool Effect.t
  | Current_sandbox : string option ref option Effect.t
  | Get_domain : string option Effect.t
  | Get_observe_all : bool Effect.t

val observe_proc : string -> string option
val capabilities : unit -> Capability.t list
val config : unit -> Types.value list
val domain : unit -> string option
val with_capabilities : Capability.t list -> (unit -> 'a) -> 'a
val with_config : Types.value -> (unit -> 'a) -> 'a
val with_handlers :
  (string * (Types.value list -> Types.value) * string) list ->
  (unit -> 'a) -> 'a
val with_domain : string -> (unit -> 'a) -> 'a
val without_observation_collection : (unit -> 'a) -> 'a
val observe_probe : string -> string option
val observe_domain_cell : string -> string -> string option
val record_read : string -> string -> unit
val config_lookup : string -> Types.value option
val observe_config : string -> string
val observe_handler : string -> string
val record_config_read : string -> unit
val record_handler_observation : string -> unit
val with_top_level : Session.t -> Invocation.t -> f:('a -> 'b) -> 'a -> 'b
