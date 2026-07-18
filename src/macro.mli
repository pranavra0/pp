(* pp macro expansion — defmacro: a function from syntax-as-values to
   syntax-as-values. The shared expansion step runs before evaluation ever
   sees a form. *)

type services = {
  eval : Types.expr -> Types.env -> Types.value;
  force_deep : Types.value -> Types.value;
  initial_env : unit -> Types.env;
}

val expand_toplevel_list : services -> Types.expr list -> Types.expr list
(** Expand all macro calls in a top-level form list, in order. Recognises
    [(defmacro (name params...) body...)] at the top level, registers the
    macro, and replaces it with [(quote name)]. Every other form is
    recursively expanded. *)
