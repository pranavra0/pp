module SS : sig
  type t = Set.Make(String).t
  val elements : t -> string list
  val for_all : (string -> bool) -> t -> bool
end
val free_vars : Core_model.expr -> SS.t
val node_free_vars : Core_model.expr -> SS.t
