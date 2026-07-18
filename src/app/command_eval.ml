open Pp_runtime
open Pp_kernel
let policy_name = function
  | Scheduler.Serial -> "serial"
  | Scheduler.Parallel n -> Printf.sprintf "parallel:%d" n
  | Scheduler.Race n -> Printf.sprintf "race:%d" n
  | Scheduler.Remote member -> Printf.sprintf "remote:%s" member

let dump_pins ctx path =
  let session = App_context.session ctx in
  let buffer = Buffer.create 256 in
  Session.iter_run_pins session (fun cell hash ->
    Buffer.add_string buffer (Remote.pin_line cell hash));
  Session.iter_probes session (fun name value ->
    match Codec.encode_value value with
    | Some text -> Buffer.add_string buffer (Remote.pin_probe_line name text)
    | None -> Printf.eprintf
      "[dump-pins] skipping non-data probe value for %s (code/handle/sealed)\n%!" name);
  Store_layout.atomic_replace path (Buffer.contents buffer)

let schedule_audit ctx cli files last =
  let scheduler = App_context.scheduler ctx in
  if Cache_policy.check_enabled Cache_policy.default &&
     Scheduler.policy scheduler <> Scheduler.Serial then
    match last with
    | None -> ()
    | Some scheduled ->
        let scheduled_hash = Identity.hash_value scheduled in
        let saved = Scheduler.policy scheduler in
        Scheduler.set_policy scheduler Scheduler.Serial;
        let serial = Fun.protect
          ~finally:(fun () -> Scheduler.set_policy scheduler saved)
          (fun () ->
            Session.begin_pass (App_context.session ctx);
            Command_run.run_files ctx cli files) in
        (match serial with
         | Some value when Identity.hash_value value <> scheduled_hash ->
             Cache_policy.note_volatile Cache_policy.default;
             Printf.eprintf
               "[check] schedule non-transparent: %s and serial re-runs produced different desired-state hashes\n%!"
               (policy_name saved)
         | _ -> ())

let run ctx cli =
  Command_island.update cli;
  Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () ->
      match Cli.eval_string cli, Cli.files cli with
      | Some expression, [] ->
          List.iter (fun value ->
            Printf.printf "%s\n" (Presentation.string_of_value value))
            (Repl.execute_string expression)
      | None, [] -> Repl.repl ()
      | _, files ->
          if Cli.watch cli then Command_watch.run ctx cli files
          else begin
            let last = Command_run.run_files ctx cli files in
            Command_reconcile.run_pass ctx cli last;
            (match Cli.dump_pins_file cli with Some path -> dump_pins ctx path | None -> ());
            schedule_audit ctx cli files last
          end) ()
