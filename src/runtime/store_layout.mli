type t
type area = Objects | Traces | Blobs | Fenced_specs | Procs | Locks
val default : t
val root : t -> string
val path : t -> area -> string -> string
val list : t -> area -> string list
val ensure_area : t -> area -> unit
val ensure_dir : string -> unit
val read : string -> string option
val atomic_replace : string -> string -> unit
val init : t -> unit
val with_lifecycle_read : (unit -> 'a) -> 'a
val with_lifecycle_write : (unit -> 'a) -> 'a
