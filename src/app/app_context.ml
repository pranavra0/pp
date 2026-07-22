open Pp_runtime
open Pp_kernel
open Source_error
type t = {
  host : Host_services.t;
  invocation : Invocation.t;
  scheduler : Scheduler.t;
  session : Session.t;
  reconciliation : Reconciliation.t;
  event_sink : Event_sink.t;
}

let read_secret path =
  let ic = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let text = really_input_string ic (in_channel_length ic) in
      let n = String.length text in
      if n > 0 && text.[n - 1] = '\n' then String.sub text 0 (n - 1) else text)

let write_secret path content =
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
  let oc = Unix.out_channel_of_descr fd in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content)

let production_host () =
  Host_services.make
    ~canonical_realpath:World_path.canonical_impl ~unix_time:Unix.time
    ~home_dir:(fun () -> Sys.getenv "HOME") ~read_secret ~write_secret

let source_roots cli =
  let raw = Sys.getcwd () :: List.map Filename.dirname (Cli.files cli) in
  let raw = match World_path.stdlib_root () with Some root -> root :: raw | None -> raw in
  List.map World_path.canonical raw

let initial_capabilities host cli =
  match Cli.remote_node cli with
  | Some (token_file, _, _, _, _) ->
      (match Cap_token.token_to_caps host (Cell_repository.read_raw token_file) with
       | Ok caps -> caps
       | Error reason -> command ("pp: --remote-node: token rejected: " ^ reason))
  | None ->
      List.map (fun spec -> Capability.mint ~realpath:host.Host_services.canonical_realpath spec)
        (Cli.grants cli)

let create host cli =
  let initial_capabilities = initial_capabilities host cli in
  let invocation =
    match Invocation.create
      ~source_roots:(source_roots cli)
      ~initial_capabilities
      ~command_argv:(Cli.command_argv cli)
      ~program_argv:(Cli.program_argv cli)
      ~program_files:(Cli.files cli)
      ~initial_grant_specs:(Cli.grants cli)
      ~program_reconcile_root:(Cli.reconcile_root cli)
      ~program_supervise:(Cli.supervise cli)
      ~program_member_name:(Cli.member_name cli)
      ~program_desired_object:(Cli.desired_object cli)
      ~gc_keep_epochs:(Cli.gc_keep_epochs cli)
      ~fenced_policy:(Cli.fenced_policy cli) with
    | Ok value -> value
    | Error message -> command ("pp: " ^ message)
  in
  let handler = Scheduler.builtin ~remote_dispatch:(Remote.dispatcher host invocation)
      (Cli.schedule_policy cli) in
  let scheduler = Scheduler.create ~handler
  in
  let event_sink = match Cli.record_file cli with
    | None -> Event_sink.noop
    | Some path ->
        let digest = Hasher.hash_concat (Cli.command_argv cli) in
        let run_id = "run-" ^ String.sub digest 0 16 in
        Event_sink.jsonl ~path ~run_id ~host_id:"local"
  in
  let session = Session.create ~event_sink ~scheduler Evaluator.operations in
  let reconciliation = Reconciliation.create ~session ~invocation in
  Store_layout.init Store_layout.default;
  Cache_policy.configure Cache_policy.default
    ~no_cache:(Cli.no_cache cli) ~why:(Cli.why cli) ~check:(Cli.check cli);
  Cache_policy.reset_volatile Cache_policy.default;
  Island.fetch_enabled := Cli.fetch_islands cli;
  Island.update_mode := Cli.update_islands cli;
  { host; invocation; scheduler; session; reconciliation; event_sink }

let host t = t.host
let invocation t = t.invocation
let scheduler t = t.scheduler
let session t = t.session
let reconciliation t = t.reconciliation
let event_sink t = t.event_sink
let close t = Event_sink.close t.event_sink
