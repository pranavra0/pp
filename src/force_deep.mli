(* Deep recursive force over a pp VALUE — the plain structural walk.
   The scheduler-aware batch dispatch lives in Primitives.force_deep;
   this is the plain walk it (and others) delegate to. *)

val force_deep_plain :
  force:(Core_model.value -> Core_model.value) -> Core_model.value -> Core_model.value

(* Find the first entry in an association list whose string-like key
   matches [key], returning its forced value. *)
val find_kv :
  force:(Core_model.value -> Core_model.value) ->
  (Core_model.value * Core_model.value) list -> string -> Core_model.value option
