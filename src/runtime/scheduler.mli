open Pp_kernel
type policy = Serial | Parallel of int | Race of int | Remote of string

type job = {
  j_key : Identity_types.Node_key.t;
  j_run : unit -> Core_model.value;
  j_width : int;
  j_thunk : Core_model.thunk;
}

type t
type handler

val handler :
  name:string ->
  redundancy:int ->
  dispatch:(job list -> unit) ->
  cancel:(unit -> unit) -> handler
val handler_name : handler -> string
val serial : handler
val builtin :
  remote_dispatch:(member:string -> job list -> unit) -> policy -> handler

val create : handler:handler -> t

val current_handler : t -> handler
val install : t -> handler -> unit
val schedules_batches : t -> bool
val redundancy : t -> int
val dispatch_batch : t -> job list -> unit
val with_signal_handler : t -> f:('a -> 'b) -> 'a -> 'b
