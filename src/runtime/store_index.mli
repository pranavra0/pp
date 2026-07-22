type graph = {
  forward : (string * string list) list;
  reverse : (string * string list) list;
}
val reverse : unit -> (string, string list) Hashtbl.t
val dirty_keys : dependency_cell:(string -> string option) -> string list ->
  (string, string list) Hashtbl.t -> string list
val graph : ?verbose:bool -> unit -> graph
val format_graph : graph -> string
val print_graph : ?verbose:bool -> unit -> unit
