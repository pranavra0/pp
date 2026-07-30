open Pp_kernel

val eval :
  Evaluator_scope.operations ->
  Core_model.observation_kind ->
  Core_model.expr list ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value
