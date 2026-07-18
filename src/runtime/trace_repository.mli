open Pp_kernel
type outcome = Ok | Failed
type trace = {
  outcome : outcome;
  result_hash : Identity_types.Object_hash.t;
  reads : (Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list;
}
type t
val create : Store_layout.t -> t
val default : t
val to_line : trace -> string
val of_line : string -> trace option
val load : t -> key:Identity_types.Cache_key.t -> trace list
val put : t -> key:Identity_types.Cache_key.t -> outcome:outcome ->
  result_hash:Identity_types.Object_hash.t ->
  reads:(Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list -> unit
val keys : t -> Identity_types.Cache_key.t list
