open Pp_kernel
type result = HitOk of Core_model.value | HitFailed of Core_model.value | Miss
type t
val create : unit -> t
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
val short_key : string -> string
val diagnose : t -> ('a, out_channel, unit, unit, unit, unit) format6 -> 'a
val lookup : t -> traces:Trace_repository.t -> objects:Object_repository.t ->
  blobs:Blob_repository.t ->
  observe_id:(Identity_types.Cell_id.t -> Identity_types.Observed_hash.t option) ->
  replay:((Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list -> unit) ->
  key:Identity_types.Cache_key.t ->
  authorized:(Identity_types.Cell_id.t -> bool) -> result
