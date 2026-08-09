type t
type area = Objects | Traces | Blobs | Fenced_specs | Procs | Locks
val of_root : string -> t
val root : t -> string
val area : t -> area -> string
val path : t -> area -> string -> string
val absolute : string -> string
val ensure_dir : string -> unit
val ensure_area : t -> area -> unit
val list : t -> area -> string list
val read : string -> string option
val atomic_replace : string -> string -> unit
val read_store : string -> string option
val open_append : string -> Unix.file_descr
val open_rw : string -> Unix.file_descr
val open_trunc : string -> Unix.file_descr
val open_read : string -> Unix.file_descr
val remove : string -> unit
val clear_dir : string -> unit
val init : t -> unit
val with_lifecycle_read : layout:t -> (unit -> 'a) -> 'a
val with_lifecycle_write : layout:t -> (unit -> 'a) -> 'a
