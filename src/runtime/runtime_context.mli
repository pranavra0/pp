type t

val create : layout:Store_layout.t -> ?cache:Cache_policy.t -> unit -> t
val current : unit -> t
val with_current : t -> ('a -> 'b) -> 'a -> 'b
val layout : unit -> Store_layout.t
val objects : unit -> Object_repository.t
val traces : unit -> Trace_repository.t
val blobs : unit -> Blob_repository.t
val cache : unit -> Cache_policy.t
val layout_of : t -> Store_layout.t
val objects_of : t -> Object_repository.t
val traces_of : t -> Trace_repository.t
val blobs_of : t -> Blob_repository.t
val cache_of : t -> Cache_policy.t
