open Pp_kernel
(* pp evaluator — strict call-by-value heap-continuation machine. *)

(** Whether a set of capabilities permits reading a trace cell.
    Used to gate cache hits on the transitive read closure. *)

val eval : Core_model.expr -> Core_model.env -> Core_model.value
(** Evaluate an expression in the given environment. *)

val eval_expressions : Core_model.expr list -> Core_model.env ref -> Core_model.value
(** Evaluate expressions sequentially, mutating the environment for
    definitions and imports. Used by [ELoad], [ELoadModule], and the REPL. *)

val eval_expressions_list :
  Core_model.expr list -> Core_model.env ref -> Core_model.value list
(** Evaluate a source's forms in one scope pass and retain each result. *)

val force : Core_model.value -> Core_model.value
(** Force a thunk to a value; passes through non-thunk values unchanged. *)


val init : Session.t -> retain_thunks:bool -> unit
(** Reset the evaluator state, clear the thunk store (unless
    thunk retention is requested), reset the macro table and gensym
    counter. *)

val operations : Evaluator_ops.t
(** The complete immutable operation graph for the sole evaluator. *)


val perform_effect : string -> Core_model.value list -> Core_model.value
(** Dispatch a named effect with its (already-forced) argument list.
    Shared by the evaluator's effect paths so they cannot drift. *)
