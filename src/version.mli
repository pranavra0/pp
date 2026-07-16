(* Single source of truth for pp's version string.
   Sourced from dune-project's (version ...) field via dune-build-info,
   embedded into the binary at build time. *)

val string : string
