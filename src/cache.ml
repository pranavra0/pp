(* pp cache — content-addressed cache, now wired to bytecode serialization *)

let cache_dir () =
  let home = match Sys.getenv_opt "HOME" with Some h -> h | None -> "/tmp" in
  Filename.concat home ".pp"

let cache_path hash =
  Filename.concat (Filename.concat (cache_dir ()) "cache") (hash ^ ".ppc")

let init () =
  let dir = cache_dir () in
  (try ignore (Sys.is_directory dir)
   with Sys_error _ ->
     let _ = Sys.command ("mkdir -p " ^ Filename.quote dir) in ());
  let cachedir = Filename.concat dir "cache" in
  (try ignore (Sys.is_directory cachedir)
   with Sys_error _ ->
     let _ = Sys.command ("mkdir -p " ^ Filename.quote cachedir) in ());
  dir

(* Save bytecode to persistent cache *)
let save (hash : string) (bc : Types.bytecode) : unit =
  let _ = init () in
  let path = cache_path hash in
  let data = Bytecode.save bc in
  try
    let ch = open_out_bin path in
    output_string ch data;
    close_out ch
  with Sys_error msg ->
    Printf.eprintf "cache: failed to save %s: %s\n%!" hash msg

(* Load bytecode from persistent cache *)
let load (hash : string) : Types.bytecode option =
  let _ = init () in
  let path = cache_path hash in
  try
    if not (Sys.file_exists path) then None
    else begin
      let ch = open_in_bin path in
      let len = in_channel_length ch in
      let data = really_input_string ch len in
      close_in ch;
      let bc = Bytecode.load data in
      Some bc
    end
  with Sys_error _ -> None

(* Save a value's bytecode representation.
   Used by the VM compilation path to cache compiled bytecode. *)
let save_value (hash : string) (v : Types.value) : unit =
  match v with
  | Types.VBytecode bc -> save hash bc
  | _ -> ()  (* non-bytecode values not cached to disk *)
