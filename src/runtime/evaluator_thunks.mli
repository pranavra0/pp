open Pp_kernel
val make : ?name:string -> Core_model.expr -> Core_model.env -> Core_model.value

val make_node :
  ?name:string ->
  Core_model.expr ->
  Core_model.env ->
  argument_hashes:string list ->
  Core_model.value

val make_typed :
  Core_model.expr ->
  Core_model.expr ->
  (string * int) option ->
  Core_model.env ->
  Core_model.value

val poison : string -> Core_model.env -> Core_model.value

val new_bindings :
  ?dedup:bool ->
  base:(string * Core_model.value) list ->
  (string * Core_model.value) list ->
  (string * Core_model.value) list
