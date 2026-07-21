exception Error of string

val string_lit : string -> string
val float_lit : float -> string

type inverted = {
  i_loc : (string * int) option;
  i_annots : (string * Pp_kernel.Core_model.expr) list;
  i_ret : Pp_kernel.Core_model.expr option;
  i_body : Pp_kernel.Core_model.expr;
}

val invert_fn_body :
  string list -> Pp_kernel.Core_model.expr -> (inverted, string) result
val block_stmts_of :
  Pp_kernel.Core_model.expr -> Pp_kernel.Core_model.expr list
val leading_anchor : Pp_kernel.Core_model.expr -> int option
