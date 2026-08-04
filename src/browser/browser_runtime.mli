(** Deterministic browser-facing execution boundary over pp's shared evaluator. *)

type result

val run : source:string -> result
val to_json : result -> string
