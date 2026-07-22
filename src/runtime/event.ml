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

let level = function
  | Run_created | Run_started | Run_finished | Run_failed -> Summary
  | Cache_trace _ | Cache_hit _ | Cache_miss _
  | Node_rebuild_started _ | Node_rebuild_finished _ | Node_rebuild_failed _ ->
      Semantic

let category = function
  | Run_created | Run_started | Run_finished | Run_failed -> "run"
  | Cache_trace _ | Cache_hit _ | Cache_miss _ -> "cache"
  | Node_rebuild_started _ | Node_rebuild_finished _ | Node_rebuild_failed _ -> "node"

let kind = function
  | Run_created -> "run.created"
  | Run_started -> "run.started"
  | Run_finished -> "run.finished"
  | Run_failed -> "run.failed"
  | Cache_trace _ -> "cache.trace.considered"
  | Cache_hit _ -> "cache.hit"
  | Cache_miss _ -> "cache.miss"
  | Node_rebuild_started _ -> "node.rebuild"
  | Node_rebuild_finished _ -> "node.rebuild"
  | Node_rebuild_failed _ -> "node.rebuild"

let phase = function
  | Run_started | Node_rebuild_started _ -> Started
  | Run_finished | Node_rebuild_finished _ -> Finished
  | Run_failed | Node_rebuild_failed _ -> Failed
  | Run_created | Cache_trace _ | Cache_hit _ | Cache_miss _ -> Instant

let visibility = function
  | Cache_trace { cell = None; status = (Stale | Unauthorized); _ } ->
      Redacted
  | _ -> Public

let escape value =
  let buffer = Buffer.create (String.length value + 8) in
  String.iter (function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '\b' -> Buffer.add_string buffer "\\b"
    | '\012' -> Buffer.add_string buffer "\\f"
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | c when Char.code c < 0x20 -> Printf.bprintf buffer "\\u%04x" (Char.code c)
    | c -> Buffer.add_char buffer c) value;
  Buffer.contents buffer

let string value = "\"" ^ escape value ^ "\""
let field name value = string name ^ ":" ^ value
let option f = function None -> "null" | Some value -> f value
let phase_name = function
  | Instant -> "instant" | Started -> "started" | Finished -> "finished" | Failed -> "failed"
let visibility_name = function Public -> "public" | Redacted -> "redacted"
let outcome_name = function Ok -> "ok" | Failed_outcome -> "failed"
let status_name = function
  | Usable -> "usable"
  | Stale -> "stale"
  | Unauthorized -> "unauthorized"
let miss_name = function
  | Cache_reads_disabled -> "cache_reads_disabled"
  | No_stored_trace -> "no_stored_trace"
  | No_usable_trace -> "no_usable_trace"
  | Result_object_missing -> "result_object_missing"

let payload_fields = function
  | Run_created | Run_started | Run_finished -> []
  | Run_failed -> []
  | Cache_trace { key; index; count; status; cell } ->
      [ field "cache_key" (string (Identity_types.Cache_key.to_string key));
        field "trace_index" (string_of_int index);
        field "trace_count" (string_of_int count);
        field "status" (string (status_name status));
        field "cell_id" (option (fun id ->
          string (Identity_types.Cell_id.to_string id)) cell) ]
  | Cache_hit { key; outcome; result_hash; cell_count } ->
      [ field "cache_key" (string (Identity_types.Cache_key.to_string key));
        field "outcome" (string (outcome_name outcome));
        field "result_hash" (string (Identity_types.Object_hash.to_string result_hash));
        field "cell_count" (string_of_int cell_count) ]
  | Cache_miss { key; reason } ->
      [ field "cache_key" (string (Identity_types.Cache_key.to_string key));
        field "reason" (string (miss_name reason)) ]
  | Node_rebuild_started key ->
      [field "node_key" (string (Identity_types.Node_key.to_string key))]
  | Node_rebuild_finished { key; result_hash } ->
      [ field "node_key" (string (Identity_types.Node_key.to_string key));
        field "result_hash" (string (Identity_types.Object_hash.to_string result_hash)) ]
  | Node_rebuild_failed { key } ->
      [field "node_key" (string (Identity_types.Node_key.to_string key))]

let to_json event =
  let fields =
    [ field "schema_version" (string_of_int event.schema_version);
      field "run_id" (string event.run_id);
      field "event_id" (string_of_int event.event_id);
      field "parent_event_id" (option string_of_int event.parent_event_id);
      field "host_id" (string event.host_id);
      field "logical_time" (string_of_int event.logical_time);
      field "category" (string event.category);
      field "kind" (string event.kind);
      field "phase" (string (phase_name event.phase));
      field "visibility" (string (visibility_name event.visibility));
      field "payload" ("{" ^ String.concat "," (payload_fields event.payload) ^ "}") ]
  in
  "{" ^ String.concat "," fields ^ "}"
