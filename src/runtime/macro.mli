open Pp_kernel
(* pp macro expansion — defmacro: a function from syntax-as-values to
   syntax-as-values. The shared expansion step runs before evaluation ever
   sees a form. *)

type services = {
  eval : Core_model.expr -> Core_model.env -> Core_model.value;
  force_deep : Core_model.value -> Core_model.value;
  initial_env : unit -> Core_model.env;
}

val expand_toplevel_list : services -> Core_model.expr list -> Core_model.expr list
(** Expand all macro calls in a top-level form list, in order. Recognises
    [(defmacro (name params...) body...)] at the top level, registers the
    macro, and replaces it with [(quote name)]. Every other form is
    recursively expanded. *)
