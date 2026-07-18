type outcome = Ok | Failed
type trace = {
  outcome : outcome;
  result_hash : string;
  reads : (string * string) list;
}
type t
val create : Store_layout.t -> t
val default : t
val to_line : trace -> string
val of_line : string -> trace option
val load : t -> key:string -> trace list
val put : t -> key:string -> outcome:outcome -> result_hash:string ->
  reads:(string * string) list -> unit
val keys : t -> string list
