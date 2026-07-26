type position = {
  offset : int;
  line : int;
  column : int;
}

type t = {
  source : string;
  start_pos : position;
  end_pos : position;
}

val position : offset:int -> line:int -> column:int -> position
val make : source:string -> start_pos:position -> end_pos:position -> t
val point : source:string -> offset:int -> line:int -> column:int -> t
val start : t -> position
val end_ : t -> position
val source : t -> string
val compare_position : position -> position -> int
val equal : t -> t -> bool
val is_empty : t -> bool
val format : t -> string
val format_start : t -> string
