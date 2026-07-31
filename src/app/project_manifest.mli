type dependency = {
  name : string;
  uri : string;
  pin : string;
}

type t = {
  path : string;
  root : string;
  name : string;
  version : string;
  entry : string;
  test_roots : string list;
  dependencies : dependency list;
}

val nearest : ?start:string -> unit -> string option
val select : string option -> string -> string
val decode_file : string -> t
val resolve_uri : root:string -> string -> string
val add_dependency : t -> name:string -> uri:string -> unit
val remove_dependency : t -> name:string -> unit
val update_dependencies : t -> string option -> unit
