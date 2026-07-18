open Pp_kernel
(* desugar — surface-independent lowering helpers.

   The shared desugars both readers and the surface layer call: block-body /
   mutual-def checking, function-body assembly (param types + return type into
   the LAW-32 shape), and the `and`/`or`/`assert` expansions. The .mli fixes the
   boundary so these lowerings have exactly one home — a reader cannot grow its
   own private copy of the `assert` desugar (a second copy would silently
   drift from this one, e.g. a form accepted by one reader and rejected by
   the other). *)

val check_block_defs :
  err:(string -> unit) -> Core_model.expr list -> Core_model.expr list

val block_body : err:(string -> unit) -> Core_model.expr list -> Core_model.expr

val assemble_fn_body :
  (Core_model.expr -> Core_model.expr) ->
  (string * Core_model.expr option) list ->
  Core_model.expr option -> Core_model.expr -> string list * Core_model.expr

val desugar_and : Core_model.expr list -> Core_model.expr
val desugar_or : Core_model.expr list -> Core_model.expr

val desugar_assert : Core_model.expr -> Core_model.expr option -> Core_model.expr

(* try-block lowering (brace surface only). [try_stmt] is the parsed statement
   vocabulary; [try_builder] is how a reader builds each lowered node (real AST
   vs quoted data); [lower_try] walks the statements once against a builder,
   with the caller owning the fresh-name counter via [fresh_var]. *)
type try_stmt = TryBind of string * Core_model.expr | TryExpr of Core_model.expr

type try_builder = {
  t_ok_kw : Core_model.expr;
  t_sym   : string -> Core_model.expr;
  t_app   : string -> Core_model.expr list -> Core_model.expr;
  t_do    : Core_model.expr list -> Core_model.expr;
  t_let   : string -> Core_model.expr -> Core_model.expr -> Core_model.expr;
  t_if    : Core_model.expr -> Core_model.expr -> Core_model.expr -> Core_model.expr;
}

val normal_try_builder : try_builder

val lower_try :
  fresh_var:(unit -> string) -> try_builder -> try_stmt list -> Core_model.expr
