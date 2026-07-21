val reverse : unit -> (string, string list) Hashtbl.t
val dirty_keys : dependency_cell:(string -> string option) -> string list ->
  (string, string list) Hashtbl.t -> string list
val print_graph : ?verbose:bool -> unit -> unit
