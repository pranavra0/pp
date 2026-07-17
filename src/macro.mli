(* pp macro expansion — defmacro: a function from syntax-as-values to
   syntax-as-values. The shared expansion step runs before evaluation ever
   sees a form. *)

val expand_toplevel_list : Types.expr list -> Types.expr list
(** Expand all macro calls in a top-level form list, in order. Recognises
    [(defmacro (name params...) body...)] at the top level, registers the
    macro, and replaces it with [(quote name)]. Every other form is
    recursively expanded. *)
