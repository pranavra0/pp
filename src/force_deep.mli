(* Deep recursive force over a pp VALUE — the plain structural walk.
   The scheduler-aware batch dispatch lives in Primitives.force_deep;
   this is the plain walk it (and others) delegate to. *)

val force_deep_plain :
  force:(Types.value -> Types.value) -> Types.value -> Types.value

(* Find the first entry in an association list whose string-like key
   matches [key], returning its forced value. *)
val find_kv :
  force:(Types.value -> Types.value) ->
  (Types.value * Types.value) list -> string -> Types.value option
