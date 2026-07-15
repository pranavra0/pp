(* desugar — surface-independent lowering helpers.

   The shared desugars both readers and the surface layer call: block-body /
   mutual-def checking, function-body assembly (param types + return type into
   the LAW-32 shape), and the `and`/`or`/`assert` expansions. The .mli fixes the
   boundary so these lowerings have exactly one home — a reader cannot grow its
   own private copy of the `assert` desugar (a second copy would silently
   drift from this one, e.g. a form accepted by one reader and rejected by
   the other). *)

val check_block_defs :
  err:(string -> unit) -> Types.expr list -> Types.expr list

val block_body : err:(string -> unit) -> Types.expr list -> Types.expr

val assemble_fn_body :
  (Types.expr -> Types.expr) ->
  (string * Types.expr option) list ->
  Types.expr option -> Types.expr -> string list * Types.expr

val desugar_and : Types.expr list -> Types.expr
val desugar_or : Types.expr list -> Types.expr

val desugar_assert :
  file:string -> line:int -> Types.expr -> Types.expr option -> Types.expr
