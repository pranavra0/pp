open Pp_kernel

type level = Summary | Semantic | Evaluation | Transport
type visibility = Public | Redacted
type phase = Instant | Started | Finished | Failed
type cache_trace_status = Usable | Stale | Unauthorized
type cache_outcome = Ok | Failed_outcome
type cache_miss_reason = Cache_reads_disabled | No_stored_trace |
  No_usable_trace | Result_object_missing
type payload =
  | Run_created
  | Run_started
  | Run_finished
  | Run_failed
  | Source_read of { content_hash : string; bytes : int }
  | Source_parsed of { form_count : int }
  | Source_macro_expanded of { form_count : int }
  | Source_error of { stage : string }
  | Cache_trace of {
      key : Identity_types.Cache_key.t;
      index : int;
      count : int;
      status : cache_trace_status;
      cell : Identity_types.Cell_id.t option;
    }
  | Cache_hit of {
      key : Identity_types.Cache_key.t;
      outcome : cache_outcome;
      result_hash : Identity_types.Object_hash.t;
      cell_count : int;
    }
  | Cache_miss of {
      key : Identity_types.Cache_key.t;
      reason : cache_miss_reason;
    }
  | Node_rebuild_started of Identity_types.Node_key.t
  | Node_rebuild_finished of {
      key : Identity_types.Node_key.t;
      result_hash : Identity_types.Object_hash.t;
    }
  | Node_rebuild_failed of {
      key : Identity_types.Node_key.t;
    }

type t = {
  schema_version : int;
  run_id : string;
  event_id : int;
  parent_event_id : int option;
  host_id : string;
  logical_time : int;
  category : string;
  kind : string;
  phase : phase;
  visibility : visibility;
  payload : payload;
}

val level : payload -> level
val category : payload -> string
val kind : payload -> string
val phase : payload -> phase
val visibility : payload -> visibility
val to_json : t -> string
