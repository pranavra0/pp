type t

val noop : t
val jsonl : path:string -> run_id:string -> host_id:string ->
  level:Event.level -> t
val buffer : Buffer.t -> run_id:string -> host_id:string -> level:Event.level -> t
val enabled : t -> bool
val accepts : t -> Event.level -> bool
val emit : t -> ?parent_event_id:int -> Event.payload -> int option
val close : t -> unit
