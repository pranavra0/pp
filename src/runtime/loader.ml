open Pp_kernel
let authorized path =
  let path = World_path.canonical path in
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let roots =
    let base =
      World_path.canonical (Filename.concat home ".pp")
      :: Invocation.source_roots (Effect.perform Dynamic_scope.Get_invocation)
    in
    match World_path.stdlib_root () with
    | Some root -> World_path.canonical root :: base
    | None -> base
  in
  List.exists (fun root -> Paths.under ~root path) roots

let invalid_std_name name =
  name = "" || name = "." || name = ".." ||
  String.exists (fun c -> c = '/' || c = '\\') name

let resolve ?source path =
  let source =
    match source with
    | Some source -> Some source
    | None -> Some (Dynamic_scope.source ())
  in
  if String.length path >= 4 && String.sub path 0 4 = "std:" then
    let name = String.sub path 4 (String.length path - 4) in
    if invalid_std_name name then
      failwith ("load: invalid std module name: " ^ path);
    match World_path.stdlib_root () with
    | None -> failwith "load: stdlib directory is unavailable"
    | Some root ->
        let resolved = Filename.concat root (name ^ ".pp") in
        if not (Sys.file_exists resolved) then
          failwith ("load: std module does not exist: " ^ name);
        (World_path.canonical resolved :> string)
  else
    let path =
      if Filename.is_relative path then
        match source with
        | Some source when source <> "" && source.[0] <> '<' ->
            Filename.concat (Filename.dirname source) path
        | _ -> path
      else path
    in
    (World_path.canonical path :> string)

let read ?source path =
  let source =
    match source with
    | Some source -> Some source
    | None -> Some (Dynamic_scope.source ())
  in
  let canonical = resolve ?source path in
  if not (authorized (canonical :> string)) then
    failwith
      ("load: " ^ path
       ^ " is outside the interpreter's source roots (loader authority is bounded to the CLI-named programs' directories, the cwd, ~/.pp, and stdlib)");
  let channel = open_in (canonical :> string) in
  let content = really_input_string channel (in_channel_length channel) in
  close_in channel;
  Observation.record (Cell.RuntimeFile (canonical :> string))
    (Hasher.hash_string content);
  content
