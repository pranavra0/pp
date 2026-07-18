open Pp_kernel
type t

val create : session:Session.t -> invocation:Invocation.t -> t
val session : t -> Session.t
val invocation : t -> Invocation.t
val should_run : t -> bool
val recover :
  t -> decide:(Journal.fenced_entry -> Fenced.recovery_decision) -> int
val run : t -> Core_model.value -> unit
