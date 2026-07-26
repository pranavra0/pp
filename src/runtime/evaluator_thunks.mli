open Pp_kernel
val make : ?name:string -> Core_model.expr -> Core_model.env -> Core_model.value

val make_node :
  ?name:string ->
  Core_model.expr ->
  Core_model.env ->
  arguments:Core_model.value list ->
  Core_model.value

val is_persistent : Core_model.thunk -> bool
val captured_capabilities : Core_model.thunk -> Capability.t list
val argument_values : Core_model.thunk -> Core_model.value list

val make_typed :
  Core_model.expr ->
  Core_model.expr ->
  Source_range.t option ->
  Core_model.env ->
  Core_model.value

val poison : string -> Core_model.env -> Core_model.value

val new_bindings :
  ?dedup:bool ->
  base:(string * Core_model.value) list ->
  (string * Core_model.value) list ->
  (string * Core_model.value) list
