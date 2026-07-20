open Pp_runtime
let update cli =
  if Cli.update_islands cli then
    List.iter (fun file ->
      let changed, skipped = Island.update_file file in
      if changed > 0 || skipped > 0 then
        Printf.eprintf "[update] %s: %d pin(s) updated, %d skipped\n%!"
          file changed skipped) (Cli.files cli)
