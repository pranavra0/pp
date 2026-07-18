val file : string -> Cell.t
val stat : string -> Cell.t
val sealed : string -> Cell.t
val tool : string -> Cell.t
val tree : string -> Cell.t
val hash_file : string -> string option
val tree_hash : string -> string
val stat_kind : string -> string
val stat_hash : string -> string
val env_hash : string option -> string
val argv_hash : string list -> string
val observe : Cell.t -> string option
val observe_id : string -> string option
val record : Cell.t -> string -> unit
val record_config : string -> unit
val record_handler : string -> unit
val replay : (string * string) list -> unit
val authorized : Capability.t list -> Cell.t -> bool
val authorized_id : Capability.t list -> string -> bool
val probe_value : string -> Core_model.value option
