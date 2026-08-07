open Pp_kernel
open Core_model

let map_fields ~force value =
  match force value with
  | VMap fields -> fields
  | other -> failwith ("runtime manifest expects a map, got " ^
      Presentation.string_of_value other)

let field ~force fields name =
  match Force_deep.find_kv ~force fields name with
  | Some value -> Some (force value)
  | None -> None

let string_field ~force fields name =
  match field ~force fields name with
  | Some (VString value) | Some (VKeyword value) -> value
  | Some value -> failwith (Printf.sprintf "runtime manifest :%s expects a string or keyword, got %s"
      name (Presentation.string_of_value value))
  | None -> failwith ("runtime manifest: missing :" ^ name)

let int_field ~force fields name =
  match field ~force fields name with
  | Some (VInt value) when value > 0 -> value
  | Some value -> failwith (Printf.sprintf "runtime manifest :%s expects a positive integer, got %s"
      name (Presentation.string_of_value value))
  | None -> failwith ("runtime manifest: missing :" ^ name)

let runtime_schedule ~force spec =
  let fields = map_fields ~force spec in
  match string_field ~force fields "kind" with
  | "serial" -> Scheduler.Serial
  | "parallel" -> Scheduler.Parallel (int_field ~force fields "width")
  | "race" -> Scheduler.Race (int_field ~force fields "width")
  | kind -> failwith ("runtime manifest: unknown schedule kind " ^ kind)

let custom_plan_value ~force ~session jobs policy =
  let descriptors = VVector (Array.of_list (List.mapi (fun index job ->
    VMap [
      VKeyword "index", VInt index;
      VKeyword "key", VString (Identity_types.Node_key.to_string job.Scheduler.j_key);
      VKeyword "width", VInt job.Scheduler.j_width
    ]) jobs)) in
  let result = Dynamic_scope.with_capabilities [] (fun () ->
    Session.call session ~env:Environment.empty policy [descriptors]) in
  let fields = map_fields ~force result in
  let mode = string_field ~force fields "mode" in
  let mode = match mode with
    | "serial" -> Scheduler.Serial_batch
    | "parallel" -> Scheduler.Parallel_batch (int_field ~force fields "width")
    | "race" -> Scheduler.Race_batch (int_field ~force fields "width")
    | "remote" -> Scheduler.Remote_batch (string_field ~force fields "member")
    | other -> failwith ("scheduler policy returned unknown mode " ^ other)
  in
  let batches = match field ~force fields "batches" with
    | Some (VVector batches) -> Array.to_list (Array.map (fun batch ->
        match force batch with
        | VVector indexes -> Array.to_list (Array.map (fun index ->
            match force index with
            | VInt index -> index
            | other -> failwith ("scheduler policy batch index must be an integer, got " ^
                Presentation.string_of_value other)) indexes)
        | other -> failwith ("scheduler policy batch must be a vector, got " ^
            Presentation.string_of_value other)) batches)
    | Some other -> failwith ("scheduler policy :batches must be a vector, got " ^
        Presentation.string_of_value other)
    | None -> failwith "scheduler policy: missing :batches"
  in
  { Scheduler.mode; batches }

let custom_scheduler ~force ~session spec =
  let fields = map_fields ~force spec in
  let policy = match field ~force fields "policy" with
    | Some (VClosure _ | VBuiltin _) as value -> Option.get value
    | Some value -> failwith ("custom schedule :policy expects a function, got " ^
        Presentation.string_of_value value)
    | None -> failwith "custom schedule: missing :policy"
  in
  let redundancy = match field ~force fields "redundancy" with
    | None -> 1
    | Some (VInt value) when value > 0 -> value
    | Some value -> failwith ("custom schedule :redundancy expects a positive integer, got " ^
        Presentation.string_of_value value)
  in
  Scheduler.custom ~name:"custom" ~redundancy
    ~remote_dispatch:(match Session.remote_dispatch session with
      | Some dispatch -> dispatch
      | None -> (fun ~member:_ _ ->
          failwith "custom schedule: remote execution requires host configuration"))
    ~plan:(fun jobs -> custom_plan_value ~force ~session jobs policy)

let validate_manifest ~force fields =
  List.iter (fun (key, value) ->
    let name = match key with
      | VKeyword name | VString name -> name
      | other -> failwith ("runtime manifest keys must be keywords or strings, got " ^
          Presentation.string_of_value other)
    in
    if not (List.mem name ["schedule"; "reporter"; "build-policy";
                           "execution-policy"]) then
      failwith ("runtime manifest has unknown field :" ^ name);
    if name = "build-policy" || name = "execution-policy" then
      if Codec.encode_value (Force_deep.force_deep value) = None then
        failwith ("runtime manifest :" ^ name ^ " must be canonical data");
    if name = "schedule" then ignore (map_fields ~force value)) fields;
  fields
