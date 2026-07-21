open Pp_kernel
val apply :
  force:(Core_model.value -> Core_model.value) ->
  fn_name:string option ->
  params:string list ->
  body:Core_model.expr ->
  closure_env:Core_model.env ref ->
  Core_model.value list ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value

val replay_reads :
  Core_model.thunk ->
  (Core_model.thunk -> Identity_types.Node_key.t) ->
  unit

val force :
  key:Identity_types.Node_key.t ->
  run:(unit -> Core_model.value) ->
  Core_model.thunk ->
  Core_model.value
