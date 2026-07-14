(* store — the durability kernel's public face (MASTER-PLAN A′4 seam).

   The content-addressed object store and the verifying-trace journal (LAW
   20/21/23/28): the write choke points ([store_object], [store_trace],
   [store_blob], [atomic_write]) that A″4's crash harness will kill around, the
   read/verify path ([load_object], [load_traces], [hit], [observe_cell]), the
   cell-id/observation helpers, and the audit/GC surface. The .mli fixes the
   boundary so durable writes route ONLY through these choke points — the path
   plumbing ([obj_path]/[trace_path]/[version_path]/[locks_dir]/…), the lock
   internals ([with_trace_lock]/[trace_lock_enabled]), and the store-lifecycle
   internals ([ensure_dirs]/[versioned_dirs]/[wipe_*]/[read_version]/…) stay
   module-private. *)

val store_root : string
val objects_dir : string
val traces_dir : string
val ensure_dir : string -> unit
val atomic_write : string -> string -> unit
val store_object : key:string -> value:Types.value -> unit
val load_object : key:string -> Types.value option
type trace_outcome = Ok | Failed
type trace = {
  tr_outcome : trace_outcome;
  tr_result_hash : string;
  tr_reads : (string * string) list;
}
val trace_to_line : trace -> string
val line_to_trace : string -> trace option
val load_traces : key:string -> trace list
val store_trace :
  key:string ->
  outcome:trace_outcome ->
  result_hash:string -> reads:(string * string) list -> unit
val file_cell_id : string -> string
val stat_cell_id : string -> string
val stat_kind : string -> string
val stat_kind_hash : string -> string
val env_cell_id : string -> string
val env_observed_hash : string option -> string
val argv_cell_id : string
val argv_observed_hash : unit -> string
val hash_file_opt : string -> string option
val tree_hash : string -> string
val blobs_dir : string
val store_blob : string -> string
val load_blob : string -> string option
val run_pins : (string, string) Hashtbl.t
val unpin_file : string -> unit
val observe_cell : string -> string option
val trace_verifies : trace -> bool
val record_file_read : string -> string -> unit
val read_raw : string -> string
val read_file_cell : string -> string
val read_sealed_cell : string -> string
type hit_result = HitOk of Types.value | HitFailed of Types.value | Miss
val no_cache : bool ref
val why_mode : bool ref
val check_mode : bool ref
val volatile_count : int ref
val gc_marking : bool ref
val gc_live : (string, unit) Hashtbl.t
val mark_live : string -> unit
val short_key : string -> string
val why : ('a, out_channel, unit, unit, unit, unit) format6 -> 'a
val hit : key:string -> authorized:(string -> bool) -> hit_result
val store_fenced_spec : hash:string -> Types.value -> unit
val load_fenced_spec : string -> Types.value option
val build_reverse_index : unit -> (string, string list) Hashtbl.t
val dirty_keys_for :
  string list -> (string, string list) Hashtbl.t -> string list
val print_graph : ?verbose:bool -> unit -> unit
val procs_dir : string
val init : unit -> unit
