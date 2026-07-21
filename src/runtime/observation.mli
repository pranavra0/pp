open Pp_kernel
val file : string -> Cell.t
val stat : string -> Cell.t
val sealed : string -> Cell.t
val tool : string -> Cell.t
val tree : string -> Cell.t
val node : string -> Cell.t
val hash_file : string -> string option
val tree_hash : string -> string
val tree_snapshot : string -> string * (string * string) list
val stat_kind : string -> string
val stat_hash : string -> string
val env_hash : string option -> string
val argv_hash : string list -> string
val observe : Cell.t -> string option
val observe_id : Identity_types.Cell_id.t -> Identity_types.Observed_hash.t option
val record : Cell.t -> string -> unit
val record_config : string -> unit
val record_handler : string -> unit
val replay :
  (Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list -> unit
val authorized : Capability.t list -> Cell.t -> bool
val authorized_id : Capability.t list -> Identity_types.Cell_id.t -> bool
val probe_value : string -> Core_model.value option
