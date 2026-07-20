val empty : Core_model.env
val extend : Core_model.env -> string -> Core_model.value -> Core_model.env
val of_bindings : (string * Core_model.value) list -> Core_model.env
val lookup : Core_model.env -> string -> Core_model.value option
val make_closure :
  ?name:string option -> string list -> Core_model.expr ->
  Core_model.env ref -> Core_model.value
val make_thunk :
  ?type_ann:Core_model.expr option ->
  ?thunk_loc:(string * int) option ->
  ?thunk_name:string option ->
  ?config_hash:string -> Core_model.expr -> Core_model.env -> Core_model.value
