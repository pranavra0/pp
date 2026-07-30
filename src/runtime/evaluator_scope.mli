open Pp_kernel
type operations = {
  eval : Core_model.expr -> Core_model.env -> Core_model.value;
  eval_tail :
    Core_model.expr -> Core_model.env -> (Core_model.value -> Core_model.value) -> Core_model.value;
  force : Core_model.value -> Core_model.value;
  apply : Core_model.value -> Core_model.value list -> Core_model.env -> Core_model.value;
}

val with_caps :
  operations ->
  Core_model.expr ->
  Core_model.expr ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value

val with_handlers :
  operations ->
  (string * Core_model.expr) list ->
  Core_model.expr ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value

val with_config :
  operations ->
  Core_model.expr ->
  Core_model.expr ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value

