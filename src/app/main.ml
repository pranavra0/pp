open Pp_app
open Pp_runtime
open Pp_kernel
let () =
  try
    let host = App_context.production_host () in
    let cli = Cli.parse (List.tl (Array.to_list Sys.argv)) in
    Command_dispatch.run host cli
  with
  | Source_error.Pp_exit n -> exit n
  | Source_error.Error error ->
      Printf.eprintf "pp: error: %s\n%!" (Source_error.string_of_t error);
      exit 1
  | Source_error.Reader_incomplete error ->
      Printf.eprintf "pp: error: %s\n%!"
        (Source_error.string_of_t (Source_error.Reader error));
      exit 1
  | Failure msg | Sys_error msg ->
      Printf.eprintf "pp: error: %s\n%!" msg;
      exit 1
