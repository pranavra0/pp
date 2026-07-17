(* runtime — the shared execution-state hub.

   pp's per-pass mutable state and the coordination API the backends drive it
   through: the ambient capability/config/handler stacks (now OCaml 5 effect
   handlers), the trace machinery ([record_read]) that turns world-reads into
   cell observations (LAW 21/23), the sandbox and loader seams, the observer
   hooks, and the program-invocation globals. This is deliberately a wide
   surface — it IS the shared state — but the .mli still fixes the boundary:
   only the coordination functions listed below are reachable from outside
   this module; their internals do not
   ([record_read] stays; [config_cell_id]/[handler_cell_id]/[config_absent_hash]/
   [builtin_handler_hash] behind [observe_config]/[observe_handler]/[config_lookup];
   [sandbox_counter] behind [current_sandbox]/[sandbox_resolve];
   [loader_authorized] behind [loader_read]; [message_has_location] behind
   [with_form_location] — all module-private). *)

type _ Effect.t +=
  | Get_capabilities : Capability.t list Effect.t
  | Get_config : Types.value list Effect.t
  | Get_handlers : (string * string) list Effect.t
  | Lookup_handler : string -> ((Types.value list -> Types.value) * string) option Effect.t
  | Record_read : string * string -> unit Effect.t
  | In_node : bool Effect.t
  | Current_sandbox : string option ref option Effect.t
  | Get_domain : string option Effect.t
  | Get_observe_all : bool Effect.t
type state = {
  mutable observe_all : bool;
  mutable observed_all : (string * string) list;
  mutable proc_observer : string -> string option;
  mutable probe_observer : string -> string option;
  mutable keep_thunks : bool;
  mutable fenced_actions : (string * Types.value) list;
  mutable island_fetch_enabled : bool;
  mutable domain_cell_observer : string -> string -> string option;
}
val state : state
val observe_proc : string -> string option
val observe_probe : string -> string option
val record_read : string -> string -> unit
val remove_tree : string -> unit
val current_sandbox : create:bool -> string option
val sandbox_resolve : ?create:bool -> string -> string option
val config_lookup : string -> Types.value option
val observe_config : string -> string
val observe_handler : string -> string
val record_config_read : string -> unit
val record_handler_observation : string -> unit
val with_top_level : f:('a -> 'b) -> 'a -> 'b
type fenced_policy = Retry | Abort | Ask
type invocation = {
  source_roots : Paths.canonical list;
  initial_capabilities : Capability.t list;
  program_argv : string list;
  program_files : string list;
  program_bytecode : bool;
  initial_grant_specs : string list;
  program_reconcile_root : string option;
  program_supervise : bool;
  program_member_name : string option;
  program_desired_object : (string * string) option;
  gc_keep_epochs : int;
  fenced_policy : fenced_policy;
}
val invocation : invocation option ref
val invocation_get : unit -> invocation
val thunk_store : (string, Types.thunk) Hashtbl.t

val stdlib_root : unit -> string option
val canonical_path : string -> Paths.canonical
val canonical_path_impl : string -> string
val loader_read : string -> string
val with_form_location : Types.expr -> (unit -> 'a) -> 'a
val fenced_policy_name : fenced_policy -> string

type domain_entry = {
  dm_namespace : string list;
  dm_observe : Types.value;
  dm_diff : Types.value option;
  dm_apply : Types.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Types.value option;
}
val domain_registry : (string, domain_entry) Hashtbl.t
val observe_domain_cell : string -> string -> string option
val probe_values : (string, Types.value) Hashtbl.t
val sealed_pins : (string, string) Hashtbl.t
