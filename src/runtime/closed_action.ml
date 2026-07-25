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
    if not (List.mem name ["tool"; "tool-path"; "args"; "inputs"; "env"; "platform"; "outputs"]) then
      failwith ("run-closed! request has unknown field :" ^ name))
    names;
  reject_duplicates "request field" names

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
      let tool_root = Filename.concat marker "tool-tree" in
      Unix.mkdir input_root 0o700;
      Unix.mkdir output_root 0o700;
      Unix.mkdir tool_root 0o700;
      Artifact_store.materialize ~root:input_root request.inputs;
      Artifact_store.materialize ~root:tool_root request.tool;
      let tool = Filename.concat tool_root request.tool_path in
      let tool_stat =
        try Unix.lstat tool
        with Unix.Unix_error _ -> failwith ("run-closed!: tool path is missing: " ^ request.tool_path)
      in
      if tool_stat.Unix.st_kind <> Unix.S_REG || tool_stat.Unix.st_perm land 0o111 = 0 then
        failwith ("run-closed!: tool path is not an executable file: " ^ request.tool_path);
      let exit_status, stdout, stderr =
        execute marker tool request.arguments request.environment
      in
      let outputs = Artifact_store.snapshot ~root:output_root ~paths:request.outputs in
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
  let tree label value =
    match Artifact_tree.of_value value with
    | Ok tree -> tree
    | Error message -> failwith ("run-closed!: invalid " ^ label ^ " tree: " ^ message)
  in
  let tool = tree ":tool" (required "tool") in
  let tool_path =
    match required "tool-path" with
    | VString path -> relative_path "tool path" path
    | _ -> failwith "run-closed! expects :tool-path to be a string"
  in
  let arguments = required "args" |> proper_list ":args" |> strings ":args" in
  let environment = required "env" |> string_map ":env" in
  let platform = required "platform" |> string_map ":platform" in
  let outputs =
    required "outputs"
    |> proper_list ":outputs"
    |> strings ":outputs"
    |> List.map (relative_path "output path")
  in
  let inputs = tree ":inputs" (required "inputs") in
  reject_duplicates "output path" outputs;
  reject_duplicates "environment name" (List.map fst environment);
  reject_duplicates "platform field" (List.map fst platform);
  List.iter (fun (name, value) ->
    if name = "" || String.contains name '=' || String.contains name '\000' then
      failwith ("run-closed!: invalid environment name: " ^ name);
    if String.contains value '\000' then
      failwith ("run-closed!: invalid environment value for: " ^ name))
    environment;
  {
    Executor.tool;
    tool_path;
    arguments;
    inputs;
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
  Artifact_store.verify result.outputs;
  VMap [
    VKeyword "exit", VInt result.exit_status;
    VKeyword "stdout", VString result.stdout;
    VKeyword "stderr", VString result.stderr;
    VKeyword "outputs",
      Artifact_tree.to_value result.outputs;
    VKeyword "evidence",
      VMap (List.map (fun (name, hash) ->
        VString name, VString hash) result.evidence);
    VKeyword "resources",
      VMap (List.map (fun (name, value) ->
        VString name, VString value) result.resources);
  ]
