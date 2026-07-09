(* Island resolution: uri -> pin -> local path *)

let update_mode = ref false

let pin_dir () =
  let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
  Filename.concat (Filename.concat home ".pp") "islands"

let pin_path uri =
  Filename.concat (pin_dir ()) (Digest.string uri ^ ".pin")

let init () =
  let dir = pin_dir () in
  (try ignore (Sys.is_directory dir)
   with Sys_error _ ->
     ignore (Sys.command ("mkdir -p " ^ Filename.quote dir)))

let resolve uri =
  init ();
  let ppath = pin_path uri in
  if Sys.file_exists ppath then
    (let ch = open_in ppath in
     let pin = input_line ch in close_in ch; Some pin)
  else None

let write_pin uri pin =
  init ();
  let ch = open_out (pin_path uri) in
  output_string ch (pin ^ "\n"); close_out ch

let clear_pin uri =
  let ppath = pin_path uri in
  if Sys.file_exists ppath then Sys.remove ppath
