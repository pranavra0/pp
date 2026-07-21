open Pp_kernel

val resolve_cmd : string -> string option
val exec : string list -> int * string * string
val run_effect : Core_model.value list -> Core_model.value
val run_dep_effect : Core_model.value list -> Core_model.value
val write_file_effect :
  has_cap:(string -> bool) -> string -> string -> Core_model.value
val read_dispatch :
  tag:string -> cap_err:(string -> string) -> string -> Core_model.value
val http_request :
  method_:string -> url:string -> body:string option -> Core_model.value
