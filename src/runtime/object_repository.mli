open Pp_kernel
type t
val create : Store_layout.t -> t
val put : t -> key:string -> value:Core_model.value -> unit
val get : t -> key:string -> Core_model.value option
val put_fenced : t -> hash:string -> Core_model.value -> unit
val get_fenced : t -> hash:string -> Core_model.value option
val keys : t -> string list
