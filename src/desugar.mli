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

val desugar_assert : Types.expr -> Types.expr option -> Types.expr

(* try-block lowering (brace surface only). [try_stmt] is the parsed statement
   vocabulary; [try_builder] is how a reader builds each lowered node (real AST
   vs quoted data); [lower_try] walks the statements once against a builder,
   with the caller owning the fresh-name counter via [fresh_var]. *)
type try_stmt = TryBind of string * Types.expr | TryExpr of Types.expr

type try_builder = {
  t_ok_kw : Types.expr;
  t_sym   : string -> Types.expr;
  t_app   : string -> Types.expr list -> Types.expr;
  t_do    : Types.expr list -> Types.expr;
  t_let   : string -> Types.expr -> Types.expr -> Types.expr;
  t_if    : Types.expr -> Types.expr -> Types.expr -> Types.expr;
}

val normal_try_builder : try_builder

val lower_try :
  fresh_var:(unit -> string) -> try_builder -> try_stmt list -> Types.expr
