type pass

val prepare_pass : Invocation.t -> Core_model.value -> pass
val run_pass : pass -> unit
val any_write_domain_registered : unit -> bool
