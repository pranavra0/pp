open Pp_kernel
(* node — the typed identity and rebuilding boundary. *)
val resolve_free_variables : expr:Core_model.expr -> env:Core_model.env ->
  force:(Core_model.value -> Core_model.value) ->
  (string * Core_model.value option) list
val authorize_free_variables : (string * Core_model.value option) list -> unit
val key_of :
  argument_values:Core_model.value list ->
  expr:Core_model.expr -> env:Core_model.env ->
  force:(Core_model.value -> Core_model.value) -> Identity_types.Node_key.t

val check_type : Core_model.value -> Core_model.expr -> (string * int) option -> unit
val enforce_type : Core_model.thunk -> Core_model.value -> unit
val record_node_dependency : Core_model.thunk -> unit
val serve_hit : t:Core_model.thunk -> Cache_policy.result -> Core_model.value option
val rebuild : key:Identity_types.Node_key.t ->
  run:(unit -> Core_model.value) -> Core_model.thunk -> Core_model.value
val lookup_hit : key:Identity_types.Node_key.t ->
  authorized:(Identity_types.Cell_id.t -> bool) -> Core_model.thunk ->
  Core_model.value option
val force : key:Identity_types.Node_key.t ->
  authorized:(Identity_types.Cell_id.t -> bool) ->
  run:(unit -> Core_model.value) -> Core_model.thunk -> Core_model.value
