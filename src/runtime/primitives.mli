open Pp_kernel
(* The builtin catalog is assembled privately; consumers receive only the
   initial environment, lookup for evaluator fallback, and its rendered audit
   table. *)

val initial_env : unit -> Core_model.env
val lookup : string -> Core_model.value option
val render_catalog : unit -> string
