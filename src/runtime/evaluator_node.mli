open Pp_kernel
val replay_reads :
  Core_model.thunk ->
  (Core_model.thunk -> Identity_types.Node_key.t) ->
  unit

val force :
  key:Identity_types.Node_key.t ->
  run:(unit -> Core_model.value) ->
  Core_model.thunk ->
  Core_model.value
