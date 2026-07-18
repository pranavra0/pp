(* pp s-expression reader.
   The .mli exposes only what callers actually use. *)

type state

val create : ?source:string -> unit -> state
val read : state -> string -> Types.expr list
val read_string : ?source:string -> string -> Types.expr list
