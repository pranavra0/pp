type entry =
  | File of { path : string; mode : int; blob : string }
  | Directory of { path : string; mode : int }
  | Symlink of { path : string; target : string }

type t = entry list

val of_value : Core_model.value -> (t, string) result
val to_value : t -> Core_model.value
val validate : t -> unit
val blob_hashes : t -> string list
val reachable_blobs : Core_model.value -> string list
