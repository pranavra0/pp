val canonical_float_string : float -> string
val hash_expr : Core_model.expr -> string
val hash_pattern : Core_model.pattern -> string
val hash_value : Core_model.value -> string
val equal_value : Core_model.value -> Core_model.value -> bool
val same_content : Core_model.value -> Core_model.value -> bool
val canonical_map_entries :
  (Core_model.value * Core_model.value) list ->
  (Core_model.value * Core_model.value) list
val canonical_set_elements : Core_model.value list -> Core_model.value list
val node_key :
  code:Core_model.expr ->
  free_variables:(string * Core_model.value option) list ->
  argument_values:Core_model.value list ->
  Identity_types.Node_key.t
