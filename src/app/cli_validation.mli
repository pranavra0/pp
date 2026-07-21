open Pp_kernel
open Pp_runtime

val schedule : string -> Scheduler.policy
val fenced_policy : string -> Invocation.fenced_policy
val nonnegative_float : option_name:string -> string -> float
val positive_int : option_name:string -> string -> int
