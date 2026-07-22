type t

val noop : t
val jsonl : path:string -> run_id:string -> host_id:string -> t
val enabled : t -> bool
val emit : t -> ?parent_event_id:int -> Event.payload -> int option
val close : t -> unit
