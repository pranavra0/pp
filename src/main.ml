let () =
  try
    let host = App_context.production_host () in
    let cli = Cli.parse (List.tl (Array.to_list Sys.argv)) in
    Command_dispatch.run host cli
  with
  | Source_error.Pp_exit n -> exit n
  | Source_error.Pp_error _ as error ->
      Printf.eprintf "pp: error: %s\n%!" (Printexc.to_string error);
      exit 1
  | Failure msg | Source_error.Capability_error msg | Sys_error msg
  | Transport.Transport_integrity_error msg ->
      Printf.eprintf "pp: error: %s\n%!" msg;
      exit 1
