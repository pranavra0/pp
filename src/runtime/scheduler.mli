open Pp_kernel
type policy = Serial | Parallel of int | Race of int | Remote of string

type job = {
  j_key : Identity_types.Node_key.t;
  j_run : unit -> Core_model.value;
  j_width : int;
  j_thunk : Core_model.thunk;
}

type t

val create :
  policy:policy ->
  remote_dispatch:(member:string -> job list -> unit) -> t

val policy : t -> policy
val set_policy : t -> policy -> unit
val dispatch_batch : t -> job list -> unit
val with_signal_handler : t -> f:('a -> 'b) -> 'a -> 'b
