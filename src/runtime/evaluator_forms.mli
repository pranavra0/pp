open Pp_kernel
type operations = {
  eval : Core_model.expr -> Core_model.env -> Core_model.value;
  eval_tail :
    Core_model.expr -> Core_model.env -> (Core_model.value -> Core_model.value) -> Core_model.value;
  force : Core_model.value -> Core_model.value;
}

type definition = {
  name : string;
  params : string list;
  body : Core_model.expr;
  kind : Core_model.closure_kind;
}

val definition_of_expr : Core_model.expr -> definition option

val do_block :
  operations ->
  Core_model.expr list ->
  Core_model.env ->
  (Core_model.value -> Core_model.value) ->
  Core_model.value

val module_expr : operations -> Core_model.expr list -> Core_model.value

val module_file : operations -> string -> Core_model.value

val load : operations -> string -> Core_model.env -> Core_model.value

val expressions :
  operations -> Core_model.expr list -> Core_model.env ref -> Core_model.value

val expressions_list :
  operations -> Core_model.expr list -> Core_model.env ref -> Core_model.value list
