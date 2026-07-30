open Pp_kernel

type shape = Any | Exact of int | Range of int * int option
type category =
  | Arithmetic | Collections | Strings | Capabilities | Observations | Effects
  | Process | Domains | Diagnostics | Metaprogramming | Other

type t

val create : unit -> t
val register :
  t ->
  ?shape:shape ->
  ?category:category ->
  string ->
  (Core_model.value list -> Core_model.env -> Core_model.value) ->
  unit
val alias : t -> alias:string -> target:string -> unit
val finalize : t -> unit
val lookup : t -> string -> Core_model.value option
val initial_env : t -> Core_model.env
val render : t -> string
