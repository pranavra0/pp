open Pp_kernel
type domain_entry = {
  dm_namespace : string list;
  dm_observe : Core_model.value;
  dm_diff : Core_model.value option;
  dm_apply : Core_model.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Core_model.value option;
}
type t

val create : scheduler:Scheduler.t -> Evaluator_ops.t -> t
val scheduler : t -> Scheduler.t
val force : t -> Core_model.value -> Core_model.value
val core_operations : t -> Evaluator_ops.core
val node_operations : t -> Evaluator_ops.node
val call : t -> env:Core_model.env -> Core_model.value -> Core_model.value list -> Core_model.value
val begin_evaluation : retain_thunks:bool -> t -> unit
val begin_pass : t -> unit
val begin_watch : t -> unit

val find_thunk : t -> string -> Core_model.thunk option
val add_thunk : t -> string -> Core_model.thunk -> unit
val find_macro : t -> string -> (string list * Core_model.expr) option
val set_macro : t -> string -> string list * Core_model.expr -> unit
val next_gensym : t -> int
val find_domain : t -> string -> domain_entry option
val register_domain : t -> string -> domain_entry -> unit
val register_probe : t -> string -> domain_entry -> unit
val fold_domains : t -> (string -> domain_entry -> 'a -> 'a) -> 'a -> 'a
val find_probe : t -> string -> Core_model.value option
val set_probe : t -> string -> Core_model.value -> unit
val preseed_probe : t -> string -> Core_model.value -> unit
val iter_probes : t -> (string -> Core_model.value -> unit) -> unit
val find_sealed_pin : t -> string -> string option
val set_sealed_pin : t -> string -> string -> unit
val observations : t -> (string * string) list
val add_observation : t -> string * string -> unit
val clear_observations : t -> unit
val add_fenced_action : t -> string * Core_model.value -> unit
val take_fenced_actions : t -> (string * Core_model.value) list
val find_run_pin : t -> string -> string option
val set_run_pin : t -> string -> string -> unit
val preseed_run_pin : t -> string -> string -> unit
val remove_run_pin : t -> string -> unit
val iter_run_pins : t -> (string -> string -> unit) -> unit
val set_node_thunk : t -> Identity_types.Node_key.t -> Core_model.thunk -> unit
val find_node_thunk : t -> Identity_types.Node_key.t -> Core_model.thunk option
val force_depth : t -> int
val set_force_depth : t -> int -> unit
val incr_force_depth : t -> unit
val decr_force_depth : t -> unit
val force_path : t -> Core_model.thunk list
val set_force_path : t -> Core_model.thunk list -> unit
val next_cache_bust : t -> int
val fenced_epoch : t -> string
val start_fenced_epoch : t -> string -> unit
val resume_fenced_epoch : t -> string -> unit
val clear_fenced_epoch : t -> unit
val next_fenced_epoch_nonce : t -> int
