open Pp_kernel

val tree_observe : string -> Core_model.value
val materialize_file : string -> string -> bool -> unit
val remove_file : string -> unit
val domain_state_get : string -> Core_model.value
val domain_state_put : string -> Core_model.value -> unit
val proc_spawn : Core_model.value -> Core_model.value
val proc_alive : int -> bool
val proc_stop : string -> int -> unit
val proc_reap : unit -> unit
