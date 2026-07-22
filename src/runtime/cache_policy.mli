open Pp_kernel
type result = HitOk of Core_model.value | HitFailed of Core_model.value | Miss
type trace_status = Usable | Stale of Identity_types.Cell_id.t |
  Unauthorized of Identity_types.Cell_id.t
type miss_reason = Cache_reads_disabled | No_stored_trace |
  No_usable_trace | Result_object_missing
type decision =
  | Cache_hit of {
      outcome : Trace_repository.outcome;
      result_hash : Identity_types.Object_hash.t;
      cell_count : int;
    }
  | Cache_miss of miss_reason
type lookup_report = {
  key : Identity_types.Cache_key.t;
  traces : (int * int * trace_status) list;
  decision : decision;
}
type t
val create : unit -> t
val default : t
val configure : t -> no_cache:bool -> why:bool -> check:bool -> unit
val enable_no_cache : t -> unit
val enable_why : t -> unit
val set_why : t -> bool -> unit
val why_enabled : t -> bool
val enable_check : t -> unit
val check_enabled : t -> bool
val volatile_count : t -> int
val reset_volatile : t -> unit
val note_volatile : t -> unit
val begin_gc : t -> unit
val end_gc : t -> (string, unit) Hashtbl.t option
val gc_marks : t -> (string, unit) Hashtbl.t
val mark : t -> string -> unit
val short_key : string -> string
val diagnose : t -> ('a, out_channel, unit, unit, unit, unit) format6 -> 'a
val format_report : authorized:(Identity_types.Cell_id.t -> bool) ->
  lookup_report -> string list
val lookup_with_report : t -> key:Identity_types.Cache_key.t ->
  authorized:(Identity_types.Cell_id.t -> bool) -> result * lookup_report
val lookup : t -> key:Identity_types.Cache_key.t ->
  authorized:(Identity_types.Cell_id.t -> bool) -> result
