val reverse : unit -> (string, string list) Hashtbl.t
val dirty_keys : string list -> (string, string list) Hashtbl.t -> string list
val print_graph : ?verbose:bool -> unit -> unit
