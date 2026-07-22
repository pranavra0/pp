open Pp_runtime
let run host cli =
  if Command_developer.run_early cli then exit 0;
  if Command_frontend.run cli then exit 0;
  let ctx = App_context.create host cli in
  let sink = App_context.event_sink ctx in
  ignore (Event_sink.emit sink Event.Run_created);
  ignore (Event_sink.emit sink
    (Event.Run_configured { event_level = Cli.event_level cli }));
  let dispatch () =
    ignore (Event_sink.emit sink Event.Run_started);
    Command_cluster.prepare ctx cli;
    Command_reconcile.recover ctx cli;
    if Command_developer.run_runtime ctx cli then exit 0;
    if Command_cluster.run_admin ctx cli then exit 0;
    if Cli.gc cli then (Command_gc.run ctx cli; exit 0);
    (match Cli.publish_object_root cli with
     | Some _ -> Command_cluster.publish ctx cli; exit 0
     | None -> ());
    (match Cli.gc_mark_out cli with
     | Some output -> Command_gc.run_mark ctx cli output; exit 0
     | None -> ());
    Command_eval.run ctx cli;
    Command_cluster.serve_remote ctx cli;
    if Cache_policy.check_enabled Cache_policy.default &&
       Cache_policy.volatile_count Cache_policy.default > 0 then begin
      Printf.eprintf "[check] FAIL: %d volatile node(s) flagged\n%!"
        (Cache_policy.volatile_count Cache_policy.default);
      exit 1
    end;
    ignore (Event_sink.emit sink Event.Run_finished)
  in
  Fun.protect
    ~finally:(fun () -> App_context.close ctx)
    (fun () ->
      try
        Scheduler.with_signal_handler (App_context.scheduler ctx)
          ~f:(fun () -> dispatch ()) ()
      with error ->
        ignore (Event_sink.emit sink Event.Run_failed);
        raise error)
