open Pp_kernel
open Core_model
open Source_error

let map_get name entries =
  List.find_map (function
    | VKeyword key, value when key = name -> Some value
    | _ -> None)
    entries

let proper_list label =
  let rec collect acc = function
    | VNil -> List.rev acc
    | VPair (head, tail) -> collect (head :: acc) tail
    | _ -> failwith ("run-closed! expects " ^ label ^ " to be a list")
  in
  collect []

let strings label values =
  List.map (function
    | VString value -> value
    | _ -> failwith ("run-closed! expects " ^ label ^ " to contain strings"))
    values

let string_map label = function
  | VMap entries ->
      List.map (function
        | VString key, VString value -> key, value
        | _ -> failwith ("run-closed! expects " ^ label ^ " to map strings to strings"))
        entries
  | _ -> failwith ("run-closed! expects " ^ label ^ " to be a map")

let blob_hash label = function
  | VString reference ->
      (match Blobref.blob_refs_in (VString reference) with
       | [hash] -> hash
       | _ -> failwith ("run-closed! expects " ^ label ^ " to be a blob reference"))
  | _ -> failwith ("run-closed! expects " ^ label ^ " to be a blob reference")

let relative_path label path =
  if path = "" || not (Filename.is_relative path) then
    failwith ("run-closed! expects a relative " ^ label ^ ": " ^ path);
  let parts = String.split_on_char '/' path in
  if List.exists (fun part -> part = "" || part = "." || part = "..") parts then
    failwith ("run-closed! rejects non-canonical " ^ label ^ ": " ^ path);
  path

let reject_duplicates label paths =
  let sorted = List.sort String.compare paths in
  let rec check = function
    | first :: second :: _ when first = second ->
        failwith ("run-closed! rejects duplicate " ^ label ^ ": " ^ first)
    | _ :: rest -> check rest
    | [] -> ()
  in
  check sorted

let validate_request entries =
  let names = List.map (function
    | VKeyword name, _ -> name
    | _ -> failwith "run-closed! request keys must be keywords")
    entries
  in
  List.iter (fun name ->
    if not (List.mem name ["tool"; "args"; "inputs"; "env"; "platform"; "outputs"]) then
      failwith ("run-closed! request has unknown field :" ^ name))
    names;
  reject_duplicates "request field" names

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let write_file path content mode =
  ensure_dir (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content);
  Unix.chmod path mode

let read_blob label hash =
  match Blob_repository.get Blob_repository.default hash with
  | Some content when Hasher.hash_string content = hash -> content
  | Some _ -> failwith (Printf.sprintf "run-closed!: %s blob hash mismatch: %s" label hash)
  | None -> failwith (Printf.sprintf "run-closed!: %s blob is missing: %s" label hash)

let runner () =
  ["/usr/bin/bwrap"; "/bin/bwrap"]
  |> List.find_opt Sys.file_exists
  |> Option.value ~default:""

let execute root tool arguments environment =
  let runner = runner () in
  if runner = "" then failwith "run-closed!: closed Linux runner unavailable: bubblewrap not found";
  let input = Filename.concat root "input" in
  let output = Filename.concat root "output" in
  let command =
    [runner; "--unshare-all"; "--die-with-parent"; "--new-session"; "--clearenv"]
    @ List.concat_map (fun (name, value) -> ["--setenv"; name; value]) environment
    @ [
     "--ro-bind"; tool; "/tool"; "--ro-bind"; input; "/in";
     "--bind"; output; "/out"; "--chdir"; "/out"; "/tool"]
    @ arguments
  in
  let code, stdout, stderr = Process.exec command in
  match code with
  | code when code <> 0
      && String.starts_with ~prefix:"bwrap:" (String.trim stderr) ->
      failwith ("run-closed!: closed Linux runner unavailable: " ^ String.trim stderr)
  | _ -> code, stdout, stderr

let collect_outputs root paths =
  let output = Filename.concat root "output" in
  let output_prefix = Unix.realpath output ^ "/" in
  List.map (fun path ->
    let path = relative_path "output path" path in
    let source = Filename.concat output path in
    let source =
      try Unix.realpath source
      with Unix.Unix_error _ ->
        failwith ("run-closed!: selected output is missing: " ^ path)
    in
    if not (String.starts_with ~prefix:output_prefix source) then
      failwith ("run-closed!: selected output escapes the output tree: " ^ path);
    let stat =
      try Unix.lstat source
      with Unix.Unix_error _ ->
        failwith ("run-closed!: selected output is missing: " ^ path)
    in
    if stat.Unix.st_kind <> Unix.S_REG then
      failwith ("run-closed!: selected output is not a regular file: " ^ path);
    let channel = open_in_bin source in
    let content =
      Fun.protect
        ~finally:(fun () -> close_in_noerr channel)
        (fun () -> really_input_string channel (in_channel_length channel))
    in
    let hash = Blob_repository.put Blob_repository.default content in
    VString path, VString ("blob:" ^ hash))
    paths

let has_process_cap () =
  List.exists Capability.check_process
    (Effect.perform Dynamic_scope.Get_capabilities)

let linux_executor () request =
  if request.Executor.platform <> ["os", "linux"] then
    failwith "run-closed!: Linux executor requires :platform -> {\"os\" -> \"linux\"}";
  let marker = Filename.temp_file "pp-closed-" "" in
  Sys.remove marker;
  Unix.mkdir marker 0o700;
  Fun.protect
    ~finally:(fun () -> Fswalk.remove_tree marker)
    (fun () ->
      let input_root = Filename.concat marker "input" in
      let output_root = Filename.concat marker "output" in
      Unix.mkdir input_root 0o700;
      Unix.mkdir output_root 0o700;
      List.iter (fun (path, hash) ->
        write_file (Filename.concat input_root path) (read_blob "input" hash) 0o400)
        request.inputs;
      let tool = Filename.concat marker "tool" in
      write_file tool (read_blob "tool" request.tool) 0o500;
      let exit_status, stdout, stderr =
        execute marker tool request.arguments request.environment
      in
      let outputs =
        collect_outputs marker request.outputs
        |> List.map (function
          | VString path, VString reference -> path, blob_hash "output value" (VString reference)
          | _ -> assert false)
      in
      {
        Executor.exit_status;
        stdout;
        stderr;
        outputs;
        evidence = [
          "clock", "ambient";
          "environment", "request-only";
          "filesystem", "request-only";
          "kernel", "ambient";
          "loader", "request-only";
          "network", "denied";
          "randomness", "ambient";
          "signals", "exit-status";
          "subprocess", "same-sandbox";
        ];
        resources = ["limits", "ambient"];
      })

let parse_request entries =
  validate_request entries;
  let required name =
    match map_get name entries with
    | Some value -> value
    | None -> failwith ("run-closed! request is missing :" ^ name)
  in
  let tool_hash = blob_hash ":tool" (required "tool") in
  let arguments = required "args" |> proper_list ":args" |> strings ":args" in
  let environment = required "env" |> string_map ":env" in
  let platform = required "platform" |> string_map ":platform" in
  let outputs =
    required "outputs"
    |> proper_list ":outputs"
    |> strings ":outputs"
    |> List.map (relative_path "output path")
  in
  let inputs =
    match required "inputs" with
    | VMap entries -> List.map (function
        | VString path, reference ->
            relative_path "input path" path, blob_hash "input value" reference
        | _ -> failwith "run-closed! expects :inputs to map string paths to blob references")
        entries
    | _ -> failwith "run-closed! expects :inputs to be a map"
  in
  reject_duplicates "output path" outputs;
  reject_duplicates "input path" (List.map fst inputs);
  reject_duplicates "environment name" (List.map fst environment);
  reject_duplicates "platform field" (List.map fst platform);
  List.iter (fun (name, value) ->
    if name = "" || String.contains name '=' || String.contains name '\000' then
      failwith ("run-closed!: invalid environment name: " ^ name);
    if String.contains value '\000' then
      failwith ("run-closed!: invalid environment value for: " ^ name))
    environment;
  {
    Executor.tool = tool_hash;
    arguments;
    inputs = List.sort compare inputs;
    environment = List.sort compare environment;
    platform = List.sort compare platform;
    outputs = List.sort String.compare outputs;
  }

let run args =
  if Effect.perform Dynamic_scope.In_node then
    failwith "run-closed!: may not be called inside a node body until the execution protocol is fully mediated";
  if not (has_process_cap ()) then
    capability "capability error: no process authority for run-closed!";
  let request =
    match args with
    | [VMap entries] -> parse_request entries
    | _ -> failwith "run-closed! expects one request map"
  in
  let executor =
    Session.executor (Effect.perform Dynamic_scope.Get_session)
    |> Option.value ~default:(fun _ ->
      failwith "run-closed!: trusted executor unavailable")
  in
  let result = Executor.run executor request in
  List.iter (fun (path, hash) ->
    ignore (read_blob ("output " ^ path) hash))
    result.outputs;
  VMap [
    VKeyword "exit", VInt result.exit_status;
    VKeyword "stdout", VString result.stdout;
    VKeyword "stderr", VString result.stderr;
    VKeyword "outputs",
      VMap (List.map (fun (path, hash) ->
        VString path, VString ("blob:" ^ hash)) result.outputs);
    VKeyword "evidence",
      VMap (List.map (fun (name, hash) ->
        VString name, VString hash) result.evidence);
    VKeyword "resources",
      VMap (List.map (fun (name, value) ->
        VString name, VString value) result.resources);
  ]
