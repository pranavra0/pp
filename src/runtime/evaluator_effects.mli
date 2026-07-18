open Pp_kernel
type application =
  Core_model.value -> Core_model.value list -> Core_model.env -> Core_model.value

val perform : application:application -> string -> Core_model.value list -> Core_model.value
