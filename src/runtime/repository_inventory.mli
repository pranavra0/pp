type kind = Object | Trace | Blob
type entry = { id : string; modified : float option }
val entries : kind -> entry list
val remove : kind -> string -> unit
