open Pp_kernel

type level = Summary | Semantic | Evaluation | Transport
type visibility = Public | Redacted
type phase = Instant | Started | Finished | Failed
type source_stage = Parse | Macro_expand
type cache_trace_status = Usable | Stale of Identity_types.Cell_id.t option | Unauthorized
type cache_outcome = Succeeded | Failed_outcome
type cache_miss_reason = Cache_reads_disabled | No_stored_trace |
  No_usable_trace | Result_object_missing
type network_operation = Request | Response | Drop | Retry | Unreachable |
  Corruption_detected
type fault_operation = Partition | Heal | Crash | Restart
type payload =
  | Run_created
  | Run_configured of { event_level : level }
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
  | Network_operation of {
      operation : network_operation;
      link_id : string;
      bytes : int;
      attempt : int;
    }
  | Fault_injected of { operation : fault_operation; target : string }
  | Scheduler_fallback of { link_id : string }
  | Metric_summary of { requests : int; retries : int; bytes : int }

type t = {
  schema_version : int;
  run_id : string;
  event_id : int;
  parent_event_id : int option;
  host_id : string;
  logical_time : int;
  wall_time_ns : int option;
  category : string;
  kind : string;
  phase : phase;
  visibility : visibility;
  payload : payload;
}

let level = function
  | Run_created | Run_configured _ | Run_started | Run_finished | Run_failed -> Summary
  | Source_read _ | Source_parsed _ | Source_macro_expanded _ | Source_error _ ->
      Semantic
  | Identity_node_key_computed _ | Identity_result_hash_computed _ -> Semantic
  | Cache_trace _ | Cache_hit _ | Cache_miss _
  | Node_rebuild_started _ | Node_rebuild_finished _ | Node_rebuild_failed _
  | Store_object_persisted _ | Store_trace_persisted _ ->
      Semantic
  | Network_operation _ | Fault_injected _ | Scheduler_fallback _ -> Semantic
  | Metric_summary _ -> Summary

let category = function
  | Run_created | Run_configured _ | Run_started | Run_finished | Run_failed -> "run"
  | Source_read _ | Source_parsed _ | Source_macro_expanded _ | Source_error _ ->
      "source"
  | Identity_node_key_computed _ | Identity_result_hash_computed _ -> "identity"
  | Cache_trace _ | Cache_hit _ | Cache_miss _ -> "cache"
  | Node_rebuild_started _ | Node_rebuild_finished _ | Node_rebuild_failed _ -> "node"
  | Store_object_persisted _ | Store_trace_persisted _ -> "store"
  | Network_operation _ -> "network"
  | Fault_injected _ -> "fault"
  | Scheduler_fallback _ -> "scheduler"
  | Metric_summary _ -> "metric"

let kind = function
  | Run_created -> "run.created"
  | Run_configured _ -> "run.configured"
  | Run_started -> "run.started"
  | Run_finished -> "run.finished"
  | Run_failed -> "run.failed"
  | Source_read _ -> "source.read"
  | Source_parsed _ -> "source.parsed"
  | Source_macro_expanded _ -> "source.macro_expanded"
  | Source_error _ -> "source.error"
  | Identity_node_key_computed _ -> "identity.node_key.computed"
  | Identity_result_hash_computed _ -> "identity.result_hash.computed"
  | Cache_trace _ -> "cache.trace.considered"
  | Cache_hit _ -> "cache.hit"
  | Cache_miss _ -> "cache.miss"
  | Node_rebuild_started _ -> "node.rebuild"
  | Node_rebuild_finished _ -> "node.rebuild"
  | Node_rebuild_failed _ -> "node.rebuild"
  | Store_object_persisted _ -> "store.object.persisted"
  | Store_trace_persisted _ -> "store.trace.persisted"
  | Network_operation { operation; _ } ->
      (match operation with
       | Request -> "network.request" | Response -> "network.response"
       | Drop -> "network.drop" | Retry -> "network.retry"
       | Unreachable -> "network.unreachable"
       | Corruption_detected -> "network.corruption_detected")
  | Fault_injected { operation; _ } ->
      (match operation with
       | Partition -> "fault.partition" | Heal -> "fault.heal"
       | Crash -> "fault.crash" | Restart -> "fault.restart")
  | Scheduler_fallback _ -> "scheduler.fallback"
  | Metric_summary _ -> "metric.summary"

let phase = function
  | Run_started | Node_rebuild_started _ -> Started
  | Run_finished | Node_rebuild_finished _ -> Finished
  | Run_failed | Source_error _ | Node_rebuild_failed _ -> Failed
  | Run_created | Run_configured _
  | Source_read _ | Source_parsed _ | Source_macro_expanded _
  | Identity_node_key_computed _ | Identity_result_hash_computed _
  | Cache_trace _ | Cache_hit _ | Cache_miss _
  | Store_object_persisted _ | Store_trace_persisted _ -> Instant
  | Network_operation _ | Fault_injected _ | Scheduler_fallback _
  | Metric_summary _ -> Instant

let visibility = function
  | Cache_trace { status = Stale None | Unauthorized; _ } -> Redacted
  | _ -> Public

let make ~run_id ~event_id ?parent_event_id ~host_id ~logical_time
    ?wall_time_ns payload = {
  schema_version = 1;
  run_id;
  event_id;
  parent_event_id;
  host_id;
  logical_time;
  wall_time_ns;
  category = category payload;
  kind = kind payload;
  phase = phase payload;
  visibility = visibility payload;
  payload;
}

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
let outcome_name = function Succeeded -> "ok" | Failed_outcome -> "failed"
let stage_name = function Parse -> "parse" | Macro_expand -> "macro_expand"
let status_name = function
  | Usable -> "usable"
  | Stale _ -> "stale"
  | Unauthorized -> "unauthorized"
let miss_name = function
  | Cache_reads_disabled -> "cache_reads_disabled"
  | No_stored_trace -> "no_stored_trace"
  | No_usable_trace -> "no_usable_trace"
  | Result_object_missing -> "result_object_missing"
let level_name = function
  | Summary -> "summary"
  | Semantic -> "semantic"
  | Evaluation -> "evaluation"
  | Transport -> "transport"

let payload_fields = function
  | Run_created | Run_started | Run_finished -> []
  | Run_configured { event_level } ->
      [field "event_level" (string (level_name event_level))]
  | Run_failed -> []
  | Source_read { content_hash; bytes } ->
      [ field "content_hash" (string content_hash);
        field "bytes" (string_of_int bytes) ]
  | Source_parsed { form_count } | Source_macro_expanded { form_count } ->
      [field "form_count" (string_of_int form_count)]
  | Source_error stage -> [field "stage" (string (stage_name stage))]
  | Identity_node_key_computed key ->
      [field "node_key" (string (Identity_types.Node_key.to_string key))]
  | Identity_result_hash_computed { key; result_hash } ->
      [ field "node_key" (string (Identity_types.Node_key.to_string key));
        field "result_hash" (string (Identity_types.Object_hash.to_string result_hash)) ]
  | Cache_trace { key; index; count; status } ->
      let cell = match status with Stale cell -> cell | Usable | Unauthorized -> None in
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
  | Store_object_persisted result_hash ->
      [field "result_hash" (string (Identity_types.Object_hash.to_string result_hash))]
  | Store_trace_persisted { key; outcome; result_hash; cell_count } ->
      [ field "cache_key" (string (Identity_types.Cache_key.to_string key));
        field "outcome" (string (outcome_name outcome));
        field "result_hash" (string (Identity_types.Object_hash.to_string result_hash));
        field "cell_count" (string_of_int cell_count) ]
  | Network_operation { link_id; bytes; attempt; _ } ->
      [ field "link_id" (string link_id); field "bytes" (string_of_int bytes);
        field "attempt" (string_of_int attempt) ]
  | Fault_injected { target; _ } -> [field "target" (string target)]
  | Scheduler_fallback { link_id } -> [field "link_id" (string link_id)]
  | Metric_summary { requests; retries; bytes } ->
      [ field "requests" (string_of_int requests);
        field "retries" (string_of_int retries);
        field "bytes" (string_of_int bytes) ]

let to_json event =
  let fields =
    [ field "schema_version" (string_of_int event.schema_version);
      field "run_id" (string event.run_id);
      field "event_id" (string_of_int event.event_id);
      field "parent_event_id" (option string_of_int event.parent_event_id);
      field "host_id" (string event.host_id);
      field "logical_time" (string_of_int event.logical_time);
      field "wall_time_ns" (option string_of_int event.wall_time_ns);
      field "category" (string event.category);
      field "kind" (string event.kind);
      field "phase" (string (phase_name event.phase));
      field "visibility" (string (visibility_name event.visibility));
      field "payload" ("{" ^ String.concat "," (payload_fields event.payload) ^ "}") ]
  in
  "{" ^ String.concat "," fields ^ "}"

type json = JObject of (string * json) list | JString of string | JInt of int | JNull

let of_json text =
  let length = String.length text in
  let error message = Error message in
  let rec value i =
    if i >= length then error "unexpected end of event JSON"
    else match text.[i] with
      | '{' -> object_fields (i + 1) []
      | '"' -> quoted (i + 1) (Buffer.create 16)
      | 'n' when i + 4 <= length && String.sub text i 4 = "null" -> Ok (JNull, i + 4)
      | '0' .. '9' -> integer i
      | _ -> error "invalid event JSON value"
  and object_fields i fields =
    if i < length && text.[i] = '}' then Ok (JObject (List.rev fields), i + 1)
    else
      match quoted_key i with
      | Error _ as e -> e
      | Ok (name, j) when j < length && text.[j] = ':' ->
          (match value (j + 1) with
           | Error _ as e -> e
           | Ok (item, k) ->
               if k < length && text.[k] = ',' then object_fields (k + 1) ((name, item) :: fields)
               else if k < length && text.[k] = '}' then Ok (JObject (List.rev ((name, item) :: fields)), k + 1)
               else error "invalid event JSON object")
      | Ok _ -> error "invalid event JSON field"
  and quoted_key i =
    if i < length && text.[i] = '"' then
      match quoted (i + 1) (Buffer.create 16) with
      | Ok (JString name, j) -> Ok (name, j)
      | Ok _ -> assert false
      | Error _ as e -> e
    else error "event JSON field name must be a string"
  and quoted i buffer =
    if i >= length then error "unterminated event JSON string"
    else match text.[i] with
      | '"' -> Ok (JString (Buffer.contents buffer), i + 1)
      | '\\' when i + 1 < length ->
          let escaped = match text.[i + 1] with
            | '"' -> Some '"' | '\\' -> Some '\\' | '/' -> Some '/'
            | 'b' -> Some '\b' | 'f' -> Some '\012' | 'n' -> Some '\n'
            | 'r' -> Some '\r' | 't' -> Some '\t' | _ -> None
          in
          (match escaped with
           | Some c -> Buffer.add_char buffer c; quoted (i + 2) buffer
           | None when text.[i + 1] = 'u' && i + 6 <= length ->
               (try
                  let code = int_of_string ("0x" ^ String.sub text (i + 2) 4) in
                  if code > 0x7f then error "non-ASCII event JSON escape"
                  else (Buffer.add_char buffer (Char.chr code); quoted (i + 6) buffer)
                with Failure _ -> error "invalid event JSON escape")
           | None -> error "unsupported event JSON escape")
      | c when Char.code c < 0x20 -> error "control byte in event JSON string"
      | c -> Buffer.add_char buffer c; quoted (i + 1) buffer
  and integer i =
    let rec finish j =
      if j < length then match text.[j] with '0' .. '9' -> finish (j + 1) | _ -> j else j
    in
    let j = finish i in
    try Ok (JInt (int_of_string (String.sub text i (j - i))), j)
    with Failure _ -> error "invalid event JSON integer"
  in
  let field name fields = List.assoc_opt name fields in
  let exact names fields = List.map fst fields = names in
  let string_field name fields = match field name fields with Some (JString s) -> Some s | _ -> None in
  let int_field name fields = match field name fields with Some (JInt n) -> Some n | _ -> None in
  let option_int_field name fields = match field name fields with Some JNull -> Some None | Some (JInt n) -> Some (Some n) | _ -> None in
  let payload kind phase fields =
    let no_fields constructor = if fields = [] then Ok constructor else error "unexpected event payload fields" in
    let one_int name constructor = match fields with [(n, JInt value)] when n = name -> Ok (constructor value) | _ -> error "invalid event payload" in
    match kind, phase with
    | "run.created", "instant" -> no_fields Run_created
    | "run.configured", "instant" ->
        (match fields with
         | [("event_level", JString level)] ->
             let level = match level with
               | "summary" -> Some Summary | "semantic" -> Some Semantic
               | "evaluation" -> Some Evaluation | "transport" -> Some Transport
               | _ -> None
             in
             (match level with Some event_level -> Ok (Run_configured { event_level }) | None -> error "invalid event level")
         | _ -> error "invalid run.configured payload")
    | "run.started", "started" -> no_fields Run_started
    | "run.finished", "finished" -> no_fields Run_finished
    | "run.failed", "failed" -> no_fields Run_failed
    | "source.read", "instant" ->
        (match fields with
         | [("content_hash", JString content_hash); ("bytes", JInt bytes)] -> Ok (Source_read { content_hash; bytes })
         | _ -> error "invalid source.read payload")
    | "source.parsed", "instant" -> one_int "form_count" (fun form_count -> Source_parsed { form_count })
    | "source.macro_expanded", "instant" -> one_int "form_count" (fun form_count -> Source_macro_expanded { form_count })
    | "source.error", "failed" ->
        (match fields with
         | [("stage", JString "parse")] -> Ok (Source_error Parse)
         | [("stage", JString "macro_expand")] -> Ok (Source_error Macro_expand)
         | _ -> error "invalid source.error payload")
    | "identity.node_key.computed", "instant" ->
        (match fields with [("node_key", JString key)] -> Ok (Identity_node_key_computed (Identity_types.Node_key.of_string key)) | _ -> error "invalid node identity payload")
    | "identity.result_hash.computed", "instant" ->
        (match fields with [("node_key", JString key); ("result_hash", JString result_hash)] -> Ok (Identity_result_hash_computed { key = Identity_types.Node_key.of_string key; result_hash = Identity_types.Object_hash.of_digest result_hash }) | _ -> error "invalid result identity payload")
    | "cache.trace.considered", "instant" ->
        (match fields with
         | [("cache_key", JString key); ("trace_index", JInt index); ("trace_count", JInt count); ("status", JString status); ("cell_id", cell)] ->
             let status = match status, cell with
               | "usable", JNull -> Some Usable
               | "stale", JNull -> Some (Stale None)
               | "stale", JString id -> Some (Stale (Some (Identity_types.Cell_id.of_string id)))
               | "unauthorized", JNull -> Some Unauthorized
               | _ -> None
             in
             let cell = match cell with JNull -> Some None | JString id -> Some (Some (Identity_types.Cell_id.of_string id)) | _ -> None in
             (match status, cell with Some status, Some _ -> Ok (Cache_trace { key = Identity_types.Cache_key.of_string key; index; count; status }) | _ -> error "invalid cache trace payload")
         | _ -> error "invalid cache trace payload")
    | "cache.hit", "instant" ->
        (match fields with
         | [("cache_key", JString key); ("outcome", JString outcome); ("result_hash", JString result_hash); ("cell_count", JInt cell_count)] ->
             let outcome = match outcome with "ok" -> Some Succeeded | "failed" -> Some Failed_outcome | _ -> None in
             (match outcome with Some outcome -> Ok (Cache_hit { key = Identity_types.Cache_key.of_string key; outcome; result_hash = Identity_types.Object_hash.of_digest result_hash; cell_count }) | None -> error "invalid cache hit outcome")
         | _ -> error "invalid cache hit payload")
    | "cache.miss", "instant" ->
        (match fields with
         | [("cache_key", JString key); ("reason", JString reason)] ->
             let reason = match reason with "cache_reads_disabled" -> Some Cache_reads_disabled | "no_stored_trace" -> Some No_stored_trace | "no_usable_trace" -> Some No_usable_trace | "result_object_missing" -> Some Result_object_missing | _ -> None in
             (match reason with Some reason -> Ok (Cache_miss { key = Identity_types.Cache_key.of_string key; reason }) | None -> error "invalid cache miss reason")
         | _ -> error "invalid cache miss payload")
    | "node.rebuild", "started" ->
        (match fields with [("node_key", JString key)] -> Ok (Node_rebuild_started (Identity_types.Node_key.of_string key)) | _ -> error "invalid node rebuild payload")
    | "node.rebuild", "finished" ->
        (match fields with [("node_key", JString key); ("result_hash", JString result_hash)] -> Ok (Node_rebuild_finished { key = Identity_types.Node_key.of_string key; result_hash = Identity_types.Object_hash.of_digest result_hash }) | _ -> error "invalid node rebuild payload")
    | "node.rebuild", "failed" ->
        (match fields with [("node_key", JString key)] -> Ok (Node_rebuild_failed { key = Identity_types.Node_key.of_string key }) | _ -> error "invalid node rebuild payload")
    | "store.object.persisted", "instant" ->
        (match fields with [("result_hash", JString result_hash)] -> Ok (Store_object_persisted (Identity_types.Object_hash.of_digest result_hash)) | _ -> error "invalid store object payload")
    | "store.trace.persisted", "instant" ->
        (match fields with
         | [("cache_key", JString key); ("outcome", JString outcome); ("result_hash", JString result_hash); ("cell_count", JInt cell_count)] ->
             let outcome = match outcome with "ok" -> Some Succeeded | "failed" -> Some Failed_outcome | _ -> None in
             (match outcome with Some outcome -> Ok (Store_trace_persisted { key = Identity_types.Cache_key.of_string key; outcome; result_hash = Identity_types.Object_hash.of_digest result_hash; cell_count }) | None -> error "invalid store trace outcome")
         | _ -> error "invalid store trace payload")
    | ("network.request" | "network.response" | "network.drop" |
       "network.retry" | "network.unreachable" |
       "network.corruption_detected"), "instant" ->
        (match fields with
         | [("link_id", JString link_id); ("bytes", JInt bytes);
            ("attempt", JInt attempt)] ->
             let operation = match kind with
               | "network.request" -> Request | "network.response" -> Response
               | "network.drop" -> Drop | "network.retry" -> Retry
               | "network.unreachable" -> Unreachable
               | "network.corruption_detected" -> Corruption_detected
               | _ -> assert false in
             Ok (Network_operation { operation; link_id; bytes; attempt })
         | _ -> error "invalid network payload")
    | ("fault.partition" | "fault.heal" | "fault.crash" |
       "fault.restart"), "instant" ->
        (match fields with
         | [("target", JString target)] ->
             let operation = match kind with
               | "fault.partition" -> Partition | "fault.heal" -> Heal
               | "fault.crash" -> Crash | "fault.restart" -> Restart
               | _ -> assert false in
             Ok (Fault_injected { operation; target })
         | _ -> error "invalid fault payload")
    | "scheduler.fallback", "instant" ->
        (match fields with
         | [("link_id", JString link_id)] -> Ok (Scheduler_fallback { link_id })
         | _ -> error "invalid scheduler fallback payload")
    | "metric.summary", "instant" ->
        (match fields with
         | [("requests", JInt requests); ("retries", JInt retries);
            ("bytes", JInt bytes)] ->
             Ok (Metric_summary { requests; retries; bytes })
         | _ -> error "invalid metric summary payload")
    | _ -> error "unknown event kind or phase"
  in
  match value 0 with
  | Error _ as e -> e
  | Ok (_, consumed) when consumed <> length -> error "trailing event JSON data"
  | Ok (JObject fields, _) ->
      let envelope = ["schema_version"; "run_id"; "event_id"; "parent_event_id"; "host_id"; "logical_time"; "wall_time_ns"; "category"; "kind"; "phase"; "visibility"; "payload"] in
      if not (exact envelope fields) then error "event envelope is not canonical"
      else
        (match int_field "schema_version" fields, string_field "run_id" fields,
               int_field "event_id" fields, option_int_field "parent_event_id" fields,
               string_field "host_id" fields, int_field "logical_time" fields,
               option_int_field "wall_time_ns" fields,
               string_field "category" fields, string_field "kind" fields,
               string_field "phase" fields, string_field "visibility" fields,
               field "payload" fields with
         | Some 1, Some run_id, Some event_id, Some parent_event_id, Some host_id,
           Some logical_time, Some wall_time_ns, Some category_name, Some kind_name, Some phase_text,
           Some visibility_text, Some (JObject payload_fields) ->
             (match payload kind_name phase_text payload_fields with
              | Error _ as e -> e
              | Ok payload_value ->
                  let expected_visibility = visibility_name (visibility payload_value) in
                  if category_name <> category payload_value || kind_name <> kind payload_value ||
                     phase_text <> phase_name (phase payload_value) || visibility_text <> expected_visibility
                  then error "event envelope disagrees with typed payload"
                  else
                    let event = make ~run_id ~event_id ?parent_event_id ~host_id
                      ~logical_time ?wall_time_ns payload_value in
                    if to_json event = text then Ok event else error "event JSON is not canonical")
         | Some _, _, _, _, _, _, _, _, _, _, _, _ -> error "unsupported event schema version"
         | _ -> error "invalid event envelope")
  | Ok _ -> error "event JSON must be an object"
