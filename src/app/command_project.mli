open Pp_kernel
open Pp_runtime

val run_early : Host_services.t -> Cli.t -> bool
val run : App_context.t -> Cli.t -> bool
