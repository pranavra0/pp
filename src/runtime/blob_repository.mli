type t
val create : Store_layout.t -> t
val put : t -> string -> string
val get : t -> string -> string option
val keys : t -> string list
