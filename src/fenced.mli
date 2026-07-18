type recovery_decision = Retry | Abort

val register : string -> Core_model.value -> unit
val recover_unknown :
  decide:(Journal.fenced_entry -> recovery_decision) -> int
val drain : unit -> unit
