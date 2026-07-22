open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message
let node_key = Identity_types.Node_key.of_string "node-key"
let cache_key = Identity_types.Cache_key.of_string "cache-key"
let result_hash = Identity_types.Object_hash.of_digest "result-hash"
let cell_id = Identity_types.Cell_id.of_string "file:/approved/input"

let event payload = {
  Event.schema_version = 1;
  run_id = "run-\"one";
  event_id = 7;
  parent_event_id = Some 3;
  host_id = "local";
  logical_time = 7;
  category = Event.category payload;
  kind = Event.kind payload;
  phase = Event.phase payload;
  visibility = Event.visibility payload;
  payload;
}

let payloads = [
  Event.Run_created;
  Event.Run_started;
  Event.Run_finished;
  Event.Run_failed;
  Event.Source_read { content_hash = "source-hash"; bytes = 12 };
  Event.Source_parsed { form_count = 2 };
  Event.Source_macro_expanded { form_count = 3 };
  Event.Source_error { stage = "parse" };
  Event.Cache_trace { key = cache_key; index = 1; count = 3; status = Event.Usable; cell = None };
  Event.Cache_trace { key = cache_key; index = 2; count = 3; status = Event.Stale; cell = Some cell_id };
  Event.Cache_trace { key = cache_key; index = 3; count = 3; status = Event.Unauthorized; cell = None };
  Event.Cache_hit { key = cache_key; outcome = Event.Succeeded; result_hash; cell_count = 2 };
  Event.Cache_hit { key = cache_key; outcome = Event.Failed_outcome; result_hash; cell_count = 1 };
  Event.Cache_miss { key = cache_key; reason = Event.Cache_reads_disabled };
  Event.Cache_miss { key = cache_key; reason = Event.No_stored_trace };
  Event.Cache_miss { key = cache_key; reason = Event.No_usable_trace };
  Event.Cache_miss { key = cache_key; reason = Event.Result_object_missing };
  Event.Node_rebuild_started node_key;
  Event.Node_rebuild_finished { key = node_key; result_hash };
  Event.Node_rebuild_failed { key = node_key };
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

let () =
  List.iter (fun payload ->
    let encoded = Event.to_json (event payload) in
    match Event.of_json encoded with
    | Ok decoded -> check (Event.to_json decoded = encoded) ("event golden drift: " ^ encoded)
    | Error message -> failwith (message ^ ": " ^ encoded)) payloads;
  let golden = Event.to_json (event Event.Run_created) in
  check (golden = "{\"schema_version\":1,\"run_id\":\"run-\\\"one\",\"event_id\":7,\"parent_event_id\":3,\"host_id\":\"local\",\"logical_time\":7,\"category\":\"run\",\"kind\":\"run.created\",\"phase\":\"instant\",\"visibility\":\"public\",\"payload\":{}}")
    "canonical event envelope changed";
  let version_two = replace_once golden "\"schema_version\":1" "\"schema_version\":2" in
  check (Result.is_error (Event.of_json version_two)) "unknown schema version was accepted";
  let wrong_category = replace_once golden "\"category\":\"run\"" "\"category\":\"node\"" in
  check (Result.is_error (Event.of_json wrong_category)) "inconsistent envelope was accepted";
  let spaced = replace_once golden "{\"schema_version\"" "{ \"schema_version\"" in
  check (Result.is_error (Event.of_json spaced)) "noncanonical JSON was accepted";
  print_endline "event: ok"
