type continuation = Core_model.value -> Core_model.value

type evaluator = {
  eval_tail : Core_model.expr -> Core_model.env -> continuation -> Core_model.value;
  set_current_env : Core_model.env -> unit;
}

val apply_tail :
  evaluator ->
  Core_model.value ->
  Core_model.value list ->
  Core_model.env ->
  continuation ->
  Core_model.value

val apply :
  evaluator ->
  Core_model.value ->
  Core_model.value list ->
  Core_model.env ->
  Core_model.value
