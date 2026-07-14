(* runtime — the shared execution-state hub (MASTER-PLAN A′4 seam).

   pp's per-pass mutable state and the coordination API the backends drive it
   through: the ambient capability/config/handler stacks, the trace machinery
   ([record_read], [push_trace_frame]/[pop_trace_frame]) that turns world-reads
   into cell observations (LAW 21/23), the sandbox and loader seams, the
   observer hooks, and the program-invocation globals. This is deliberately a
   wide surface — it IS the shared state — but the .mli still fixes the
   boundary: the coordination functions cross it, their internals do not
   ([record_read] stays; [config_cell_id]/[handler_cell_id]/[config_absent_hash]/
   [builtin_handler_hash] behind [observe_config]/[observe_handler]/[config_lookup];
   [sandbox_stack]/[sandbox_counter] behind [current_sandbox]/[sandbox_resolve];
   [loader_authorized] behind [loader_read]; [message_has_location] behind
   [with_form_location] — all module-private). *)

val handler_stack :
  (string * (Types.value list -> Types.value) * string) list ref
val handlers_hash : unit -> string
val current_capabilities : Types.capability list ref
val config_stack : Types.value list ref
val thunk_store : (string, Types.thunk) Hashtbl.t
val with_ref : 'a ref -> 'a -> (unit -> 'b) -> 'b
val trace_stack : (string * string) list ref list ref
val observe_all : bool ref
val observed_all : (string * string) list ref
val record_read : string -> string -> unit
val remove_tree : string -> unit
val current_sandbox : create:bool -> string option
val sandbox_resolve : ?create:bool -> string -> string option
val push_trace_frame : unit -> (string * string) list ref
val pop_trace_frame : unit -> unit
val force_hook : (Types.value -> Types.value) ref
val proc_observer : (string -> string option) ref
val observe_proc : string -> string option
val probe_observer : (string -> string option) ref
val observe_probe : string -> string option
val config_lookup : string -> Types.value option
val observe_config : string -> string
val observe_handler : string -> string
val record_config_read : string -> unit
val record_handler_observation : string -> unit
val source_roots : string list ref
val stdlib_root : unit -> string option
val canonical_path : string -> string
val loader_read : string -> string
val with_form_location : Types.expr -> (unit -> 'a) -> 'a
val initial_capabilities : Types.capability list ref
val program_argv : string list ref
val program_files : string list ref
val program_bytecode : bool ref
val initial_grant_specs : string list ref
val program_reconcile_root : string option ref
val program_supervise : bool ref
val program_member_name : string option ref
val program_desired_object : (string * string) option ref
val gc_keep_epochs : int ref
val keep_thunks : bool ref
val fenced_actions : (string * Types.value) list ref
val island_fetch_enabled : bool ref
type fenced_policy = Retry | Abort | Ask
val fenced_policy : fenced_policy ref
val fenced_policy_name : fenced_policy -> string
type domain_entry = {
  dm_namespace : string list;
  dm_observe : Types.value;
  dm_diff : Types.value option;
  dm_apply : Types.value option;
  dm_cap : Types.capability;
  dm_observe_cell : Types.value option;
}
val domain_registry : (string, domain_entry) Hashtbl.t
val current_domain : string option ref
val domain_cell_observer : (string -> string -> string option) ref
val observe_domain_cell : string -> string -> string option
val probe_values : (string, Types.value) Hashtbl.t
val sealed_pins : (string, string) Hashtbl.t
