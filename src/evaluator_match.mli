val eval :
  force:(Core_model.value -> Core_model.value) ->
  eval:(Core_model.expr -> Core_model.env -> Core_model.value) ->
  eval_tail:
    (Core_model.expr -> Core_model.env -> (Core_model.value -> Core_model.value) -> Core_model.value) ->
  Core_model.value ->
  (Core_model.pattern * Core_model.expr option * Core_model.expr) list ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value
