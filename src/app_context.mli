type t

val host : t -> Host_services.t
val invocation : t -> Invocation.t
val scheduler : t -> Scheduler.t
val session : t -> Session.t
val reconciliation : t -> Reconciliation.t
val create : Host_services.t -> Cli.t -> t
val production_host : unit -> Host_services.t
