open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message
let node_key = Identity_types.Node_key.of_string "node-key"
let cache_key = Identity_types.Cache_key.of_string "cache-key"
let result_hash = Identity_types.Object_hash.of_digest "result-hash"
let cell_id = Identity_types.Cell_id.of_string "file:/approved/input"

let event payload = Event.make ~run_id:"run-\"one" ~event_id:7
  ~parent_event_id:3 ~host_id:"local" ~logical_time:7 payload

let payloads = [
  Event.Run_created;
  Event.Run_configured { event_level = Event.Summary };
  Event.Run_configured { event_level = Event.Semantic };
  Event.Run_configured { event_level = Event.Evaluation };
  Event.Run_configured { event_level = Event.Transport };
  Event.Run_started;
  Event.Run_finished;
  Event.Run_failed;
  Event.Source_read { content_hash = "source-hash"; bytes = 12 };
  Event.Source_parsed { form_count = 2 };
  Event.Source_macro_expanded { form_count = 3 };
  Event.Source_error Event.Parse;
  Event.Source_error Event.Macro_expand;
  Event.Identity_node_key_computed node_key;
  Event.Identity_result_hash_computed { key = node_key; result_hash };
  Event.Cache_trace { key = cache_key; index = 1; count = 3; status = Event.Usable };
  Event.Cache_trace { key = cache_key; index = 2; count = 3; status = Event.Stale (Some cell_id) };
  Event.Cache_trace { key = cache_key; index = 2; count = 3; status = Event.Stale None };
  Event.Cache_trace { key = cache_key; index = 3; count = 3; status = Event.Unauthorized };
  Event.Cache_hit { key = cache_key; outcome = Event.Succeeded; result_hash; cell_count = 2 };
  Event.Cache_hit { key = cache_key; outcome = Event.Failed_outcome; result_hash; cell_count = 1 };
  Event.Cache_miss { key = cache_key; reason = Event.Cache_reads_disabled };
  Event.Cache_miss { key = cache_key; reason = Event.No_stored_trace };
  Event.Cache_miss { key = cache_key; reason = Event.No_usable_trace };
  Event.Cache_miss { key = cache_key; reason = Event.Result_object_missing };
  Event.Node_rebuild_started node_key;
  Event.Node_rebuild_finished { key = node_key; result_hash };
  Event.Node_rebuild_failed { key = node_key };
  Event.Store_object_persisted result_hash;
  Event.Store_trace_persisted { key = cache_key; outcome = Event.Succeeded; result_hash; cell_count = 2 };
  Event.Store_trace_persisted { key = cache_key; outcome = Event.Failed_outcome; result_hash; cell_count = 1 };
  Event.Network_operation { operation = Event.Request; link_id = "a-b"; bytes = 12; attempt = 1 };
  Event.Network_operation { operation = Event.Response; link_id = "a-b"; bytes = 12; attempt = 1 };
  Event.Network_operation { operation = Event.Drop; link_id = "a-b"; bytes = 12; attempt = 1 };
  Event.Network_operation { operation = Event.Retry; link_id = "a-b"; bytes = 12; attempt = 2 };
  Event.Network_operation { operation = Event.Unreachable; link_id = "a-b"; bytes = 12; attempt = 2 };
  Event.Network_operation { operation = Event.Corruption_detected; link_id = "a-b"; bytes = 12; attempt = 2 };
  Event.Fault_injected { operation = Event.Partition; target = "a-b" };
  Event.Fault_injected { operation = Event.Heal; target = "a-b" };
  Event.Fault_injected { operation = Event.Crash; target = "worker" };
  Event.Fault_injected { operation = Event.Restart; target = "worker" };
  Event.Scheduler_fallback { link_id = "a-b" };
  Event.Metric_summary { requests = 3; retries = 2; bytes = 12 };
  Event.Runtime_boundary { boundary = Event.Evaluation_enter; subject = "expression"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Evaluation_exit; subject = "expression"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Evaluation_fail; subject = "expression"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Scheduler_dispatch; subject = "remote:worker"; count = 2 };
  Event.Runtime_boundary { boundary = Event.Process_spawn; subject = "cc"; count = 3 };
  Event.Runtime_boundary { boundary = Event.Process_exit; subject = "cc"; count = 0 };
  Event.Runtime_boundary { boundary = Event.Capability_allowed; subject = "process"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Capability_denied; subject = "process"; count = 0 };
  Event.Runtime_boundary { boundary = Event.Domain_observe; subject = "fs"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Domain_diff; subject = "fs"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Domain_apply; subject = "fs"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Domain_verify; subject = "fs"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Reconcile_start; subject = "pass"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Reconcile_finish; subject = "pass"; count = 1 };
  Event.Runtime_boundary { boundary = Event.Watch_poll; subject = "cells"; count = 2 };
  Event.Runtime_boundary { boundary = Event.Watch_changed; subject = "cells"; count = 1 };
]

let replace_once source before after =
  let rec find start =
    if start + String.length before > String.length source then raise Not_found
    else if String.sub source start (String.length before) = before then start
    else find (start + 1)
  in
  let start = find 0 in
  String.sub source 0 start ^ after ^
  String.sub source (start + String.length before)
    (String.length source - start - String.length before)

let contains source fragment =
  try ignore (replace_once source fragment fragment); true with Not_found -> false

let read_lines path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
    let rec loop lines =
      match input_line channel with
      | line -> loop (line :: lines)
      | exception End_of_file -> List.rev lines
    in
    loop [])

let () =
  List.iter (fun payload ->
    let encoded = Event.to_json (event payload) in
    match Event.of_json encoded with
    | Ok decoded -> check (Event.to_json decoded = encoded) ("event golden drift: " ^ encoded)
    | Error message -> failwith (message ^ ": " ^ encoded)) payloads;
  let golden = Event.to_json (event Event.Run_created) in
  check (golden = "{\"schema_version\":1,\"run_id\":\"run-\\\"one\",\"event_id\":7,\"parent_event_id\":3,\"host_id\":\"local\",\"logical_time\":7,\"wall_time_ns\":null,\"category\":\"run\",\"kind\":\"run.created\",\"phase\":\"instant\",\"visibility\":\"public\",\"payload\":{}}")
    "canonical event envelope changed";
  let version_two = replace_once golden "\"schema_version\":1" "\"schema_version\":2" in
  check (Result.is_error (Event.of_json version_two)) "unknown schema version was accepted";
  let wrong_category = replace_once golden "\"category\":\"run\"" "\"category\":\"node\"" in
  check (Result.is_error (Event.of_json wrong_category)) "inconsistent envelope was accepted";
  let spaced = replace_once golden "{\"schema_version\"" "{ \"schema_version\"" in
  check (Result.is_error (Event.of_json spaced)) "noncanonical JSON was accepted";
  let escaped = Event.to_json (Event.make ~run_id:"run\001" ~event_id:1
    ~host_id:"local" ~logical_time:1 Event.Run_created) in
  check (match Event.of_json escaped with Ok decoded -> Event.to_json decoded = escaped | Error _ -> false)
    "canonical control escape did not round-trip";
  let live = Event.to_json (Event.make ~run_id:"run" ~event_id:1
    ~host_id:"local" ~logical_time:1 ~wall_time_ns:42 Event.Run_created) in
  check (match Event.of_json live with Ok decoded -> Event.to_json decoded = live | Error _ -> false)
    "optional wall timestamp did not round-trip";
  let leaked = Event.to_json (event (Event.Cache_trace {
    key = cache_key; index = 1; count = 1; status = Event.Unauthorized;
  })) in
  check (contains leaked "\"visibility\":\"redacted\"") "redacted visibility did not encode";
  check (contains leaked "\"cell_id\":null") "unauthorized cell identity was not erased";
  check (not (contains leaked "approved/input")) "unauthorized cell identity entered an event";
  let injected = replace_once leaked "\"cell_id\":null"
    "\"cell_id\":\"file:/approved/input\"" in
  check (Result.is_error (Event.of_json injected))
    "decoder admitted an unauthorized cell identity";
  check (not (Event_sink.accepts Event_sink.noop Event.Summary)) "no-op sink accepted events";
  check (Event_sink.emit Event_sink.noop Event.Run_created = None) "no-op sink allocated an id";
  let path = Filename.temp_file "pp-event-unit" ".jsonl" in
  let sink = Event_sink.jsonl ~path ~run_id:"run" ~host_id:"host" ~level:Event.Summary in
  check (Event_sink.accepts sink Event.Summary) "summary sink rejected summary event";
  check (not (Event_sink.accepts sink Event.Semantic)) "summary sink accepted semantic event";
  check (Event_sink.emit sink (Event.Source_parsed { form_count = 1 }) = None)
    "filtered event allocated an id";
  check (Event_sink.emit sink Event.Run_created = Some 1) "first emitted id was not one";
  check (Event_sink.emit sink Event.Run_finished = Some 2) "filtered event left an id gap";
  Event_sink.close sink;
  let lines = read_lines path in
  Sys.remove path;
  check (List.length lines = 2) "summary sink wrote a filtered event";
  List.iter (fun line -> check (Result.is_ok (Event.of_json line)) "sink wrote invalid JSON") lines;
  print_endline "event: ok"
