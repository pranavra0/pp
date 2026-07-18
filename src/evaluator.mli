(* pp evaluator — strict (call-by-value) tree-walking evaluator.

   Public surface exposed to callers: init/reset, force/eval of thunks
   and expressions, node caching (force_node), effect dispatch, trace
   replay for persistent nodes, capability-gated cell-authority checks,
   and the REPL's eval_expressions entry point. *)

(** LAW 23b: whether a set of capabilities permits reading a trace cell.
    Used to gate cache hits on the transitive read closure. *)

val eval : Core_model.expr -> Core_model.env -> Core_model.value
(** Evaluate an expression in the given environment. *)

val eval_expressions : Core_model.expr list -> Core_model.env ref -> Core_model.value
(** Evaluate expressions sequentially, mutating the environment for
    definitions and imports. Used by [ELoad], [ELoadModule], and the REPL. *)

val force : Core_model.value -> Core_model.value
(** Force a thunk to a value; passes through non-thunk values unchanged. *)

val force_node :
  key:string -> run:(unit -> Core_model.value) -> Core_model.thunk -> Core_model.value
(** Force a persistent node through the store: serve a verified hit (gated
    on the caller's authority over the trace's read closure, LAW 23b),
    re-serve a memoized failure (LAW 28), or run and store on a miss. *)

val init : Session.t -> retain_thunks:bool -> unit
(** Reset the evaluator state, clear the thunk store (unless
    thunk retention is requested), reset the macro table and gensym
    counter. *)

val operations : Evaluator_ops.t
(** The complete immutable operation graph for the sole evaluator. *)

val is_data_closed : Core_model.thunk -> bool
(** Check whether a thunk's free variables are data-closed (no capabilities
    or sealed values leaked through). Used by remote dispatch to decide
    whether a job can be shipped to a cluster member. *)

val perform_effect : string -> Core_model.value list -> Core_model.value
(** Dispatch a named effect with its (already-forced) argument list.
    Shared by the evaluator's effect paths so they cannot drift. *)

val replay_node_reads : Core_model.thunk -> (Core_model.thunk -> string) -> unit
(** Trace replay for an already-Evaluated persistent node: replay its
    stored trace reads into the active trace frames so the caller's trace
    transitively captures this node's world-reads. [key_of] is the
    backend's node-key function. *)
