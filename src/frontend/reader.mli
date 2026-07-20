open Pp_kernel
(* pp s-expression reader.
   The .mli exposes only what callers actually use. *)

type state

val create : ?source:string -> unit -> state
val read : state -> string -> Core_model.expr list

val read_string : ?source:string -> string -> Core_model.expr list
