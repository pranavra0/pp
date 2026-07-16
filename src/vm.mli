(* vm — the bytecode VM interface.

   The stack-based virtual machine executing bytecode. Only [init] and
   [run_program_expr] are exposed; the loop, stack, globals, and other
   internals are module-private. *)

val init : unit -> unit
(** Reset the VM state, re-register primitives, and wire the backend hooks.
    Called before any VM execution. *)

val run_program_expr : Types.bytecode -> Types.value
(** Run a single compiled bytecode program without re-initialising VM state.
    Returns the top-of-stack value at HALT/RETURN, or [VEnvMap] for a
    module expression. *)
