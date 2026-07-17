(* pp evaluator — strict (call-by-value) tree-walking evaluator.

   Public surface exposed to callers: init/reset, force/eval of thunks
   and expressions, node caching (force_node), effect dispatch, trace
   replay for persistent nodes, capability-gated cell-authority checks,
   and the REPL's eval_expressions entry point. *)

val cell_authorized_for : Capability.t list -> string -> bool
(** LAW 23b: whether a set of capabilities permits reading a trace cell.
    Used to gate cache hits on the transitive read closure. *)

val eval : Types.expr -> Types.env -> Types.value
(** Evaluate an expression in the given environment. *)

val eval_expressions : Types.expr list -> Types.env ref -> Types.value
(** Evaluate expressions sequentially, mutating the environment for
    definitions and imports. Used by [ELoad], [ELoadModule], and the REPL. *)

val force : Types.value -> Types.value
(** Force a thunk to a value; passes through non-thunk values unchanged. *)

val force_node :
  key:string -> run:(unit -> Types.value) -> Types.thunk -> Types.value
(** Force a persistent node through the store: serve a verified hit (gated
    on the caller's authority over the trace's read closure, LAW 23b),
    re-serve a memoized failure (LAW 28), or run and store on a miss. *)

val init : unit -> unit
(** Reset the evaluator state, clear the thunk store (unless
    [Runtime.keep_thunks] is set), reset the macro table and gensym
    counter, and wire the backend hooks for [force]/[eval]/[apply]. *)

val is_data_closed : Types.thunk -> bool
(** Check whether a thunk's free variables are data-closed (no capabilities
    or sealed values leaked through). Used by remote dispatch to decide
    whether a job can be shipped to a cluster member. *)

val perform_effect : string -> Types.value list -> Types.value
(** Dispatch a named effect with its (already-forced) argument list.
    Shared by the evaluator's effect paths so they cannot drift. *)

val replay_node_reads : Types.thunk -> (Types.thunk -> string) -> unit
(** Trace replay for an already-Evaluated persistent node: replay its
    stored trace reads into the active trace frames so the caller's trace
    transitively captures this node's world-reads. [key_of] is the
    backend's node-key function. *)
