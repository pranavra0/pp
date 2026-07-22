open Js_of_ocaml
open Pp_kernel
open Pp_runtime

let invocation () =
  match Invocation.create
    ~source_roots:[Paths.canonicalize ~realpath:Fun.id "/"]
    ~initial_capabilities:[] ~command_argv:["pp"; "browser"]
    ~program_argv:[] ~program_files:[] ~initial_grant_specs:[]
    ~program_reconcile_root:None ~program_supervise:false
    ~program_member_name:None ~program_desired_object:None ~gc_keep_epochs:2
    ~fenced_policy:Invocation.Retry with
  | Ok invocation -> invocation
  | Error message -> failwith message

let quote text =
  let buffer = Buffer.create (String.length text + 8) in
  Buffer.add_char buffer '"';
  String.iter (function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\r' -> Buffer.add_string buffer "\\r"
    | '\t' -> Buffer.add_string buffer "\\t"
    | c -> Buffer.add_char buffer c) text;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let json_strings values =
  "[" ^ String.concat "," (List.map quote values) ^ "]"

let run source_name source =
  Store_layout.init Store_layout.default;
  Cache_policy.configure Cache_policy.default ~no_cache:false ~why:false ~check:false;
  let recording = Buffer.create 4096 in
  let sink = Event_sink.buffer recording ~run_id:"browser" ~host_id:"browser"
      ~level:Event.Semantic in
  let scheduler = Scheduler.create ~handler:Scheduler.serial in
  let session = Session.create ~event_sink:sink ~scheduler Evaluator.operations in
  let invocation = invocation () in
  ignore (Event_sink.emit sink Event.Run_created);
  ignore (Event_sink.emit sink Event.Run_started);
  try
    let values = Dynamic_scope.with_top_level session invocation ~f:(fun () ->
      Repl.execute_string ~source:source_name source) () in
    ignore (Event_sink.emit sink Event.Run_finished);
    let output = String.concat "\n" (List.map Presentation.string_of_value values) in
    let hashes = List.map Identity.hash_value values in
    "{\"ok\":true,\"output\":" ^ quote output ^ ",\"result_hashes\":"
    ^ json_strings hashes ^ ",\"host_services\":{\"filesystem\":\"virtual\",\"process\":\"unavailable\",\"network\":\"unavailable\"},\"events\":"
    ^ quote (Buffer.contents recording) ^ "}"
  with error ->
    ignore (Event_sink.emit sink Event.Run_failed);
    "{\"ok\":false,\"error\":" ^ quote (Printexc.to_string error)
    ^ ",\"host_services\":{\"filesystem\":\"virtual\",\"process\":\"unavailable\",\"network\":\"unavailable\"},\"events\":"
    ^ quote (Buffer.contents recording) ^ "}"

let () =
  Js.Unsafe.set Js.Unsafe.global "ppBrowser" (object%js
    method run source_name source =
      Js.string (run (Js.to_string source_name) (Js.to_string source))
  end)
