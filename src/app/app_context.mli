open Pp_runtime
open Pp_kernel
type t

val host : t -> Host_services.t
val invocation : t -> Invocation.t
val scheduler : t -> Scheduler.t
val session : t -> Session.t
val reconciliation : t -> Reconciliation.t
val event_sink : t -> Event_sink.t
val close : t -> unit
val create : Host_services.t -> Cli.t -> t
val production_host : unit -> Host_services.t
