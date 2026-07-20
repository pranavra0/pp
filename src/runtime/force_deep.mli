open Pp_kernel
(* Deep recursive force over a pp value, with scheduler batching where enabled. *)

val force_deep : Core_model.value -> Core_model.value

val force_deep_plain :
  force:(Core_model.value -> Core_model.value) -> Core_model.value -> Core_model.value

(* Find the first entry in an association list whose string-like key
   matches [key], returning its forced value. *)
val find_kv :
  force:(Core_model.value -> Core_model.value) ->
  (Core_model.value * Core_model.value) list -> string -> Core_model.value option
