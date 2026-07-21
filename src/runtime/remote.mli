open Pp_kernel

val pin_line : string -> string -> string
val pin_probe_line : string -> Core_model.value -> string
val preseed_pins_from_file : Session.t -> pins_file:string -> unit
val serve_assigned_keys :
  Host_services.t ->
  token_text:string ->
  keys_file:string ->
  shared_root:string ->
  reply_file:string ->
  unit
val dispatcher :
  Host_services.t ->
  Invocation.t ->
  member:string ->
  Scheduler.job list ->
  unit
