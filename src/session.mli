type domain_entry = {
  dm_namespace : string list;
  dm_observe : Types.value;
  dm_diff : Types.value option;
  dm_apply : Types.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Types.value option;
}
type t

val create : unit -> t
val begin_evaluation : retain_thunks:bool -> t -> unit
val begin_pass : t -> unit
val begin_watch : t -> unit

val find_thunk : t -> string -> Types.thunk option
val add_thunk : t -> string -> Types.thunk -> unit
val find_macro : t -> string -> (string list * Types.expr) option
val set_macro : t -> string -> string list * Types.expr -> unit
val next_gensym : t -> int
val find_domain : t -> string -> domain_entry option
val set_domain : t -> string -> domain_entry -> unit
val fold_domains : t -> (string -> domain_entry -> 'a -> 'a) -> 'a -> 'a
val find_probe : t -> string -> Types.value option
val set_probe : t -> string -> Types.value -> unit
val iter_probes : t -> (string -> Types.value -> unit) -> unit
val find_sealed_pin : t -> string -> string option
val set_sealed_pin : t -> string -> string -> unit
val observations : t -> (string * string) list
val add_observation : t -> string * string -> unit
val clear_observations : t -> unit
val add_fenced_action : t -> string * Types.value -> unit
val take_fenced_actions : t -> (string * Types.value) list
val find_run_pin : t -> string -> string option
val set_run_pin : t -> string -> string -> unit
val remove_run_pin : t -> string -> unit
val iter_run_pins : t -> (string -> string -> unit) -> unit
val set_node_thunk : t -> string -> Types.thunk -> unit
val find_node_thunk : t -> string -> Types.thunk option
val set_probe_observer : t -> (string -> string option) -> unit
val observe_probe : t -> string -> string option
val set_domain_observer : t -> (string -> string -> string option) -> unit
val observe_domain : t -> string -> string -> string option
val current_env : t -> Types.env
val set_current_env : t -> Types.env -> unit
val force_depth : t -> int
val set_force_depth : t -> int -> unit
val incr_force_depth : t -> unit
val decr_force_depth : t -> unit
val next_cache_bust : t -> int
val fenced_epoch : t -> string
val set_fenced_epoch : t -> string -> unit
