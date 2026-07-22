open Pp_kernel

type level = Summary | Semantic | Evaluation | Transport
type visibility = Public | Redacted
type phase = Instant | Started | Finished | Failed
type source_stage = Parse | Macro_expand
type cache_trace_status = Usable | Stale of Identity_types.Cell_id.t option | Unauthorized
type cache_outcome = Succeeded | Failed_outcome
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
  | Source_error of source_stage
  | Identity_node_key_computed of Identity_types.Node_key.t
  | Identity_result_hash_computed of {
      key : Identity_types.Node_key.t;
      result_hash : Identity_types.Object_hash.t;
    }
  | Cache_trace of {
      key : Identity_types.Cache_key.t;
      index : int;
      count : int;
      status : cache_trace_status;
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
  | Store_object_persisted of Identity_types.Object_hash.t
  | Store_trace_persisted of {
      key : Identity_types.Cache_key.t;
      outcome : cache_outcome;
      result_hash : Identity_types.Object_hash.t;
      cell_count : int;
    }

type t = private {
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

val make : run_id:string -> event_id:int -> ?parent_event_id:int ->
  host_id:string -> logical_time:int -> payload -> t
val level : payload -> level
val category : payload -> string
val kind : payload -> string
val phase : payload -> phase
val visibility : payload -> visibility
val to_json : t -> string
val of_json : string -> (t, string) result
