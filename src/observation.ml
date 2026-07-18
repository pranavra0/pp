open Core_model

let canonical path = (World_path.canonical path :> string)
let file path = Cell.File (canonical path)
let stat path = Cell.Stat (canonical path)
let sealed path = Cell.Sealed (canonical path)
let tool path = Cell.Tool (canonical path)
let tree path = Cell.Tree (canonical path)

let hash_file path =
  try
    let ic = open_in_bin path in
    let content = really_input_string ic (in_channel_length ic) in
    close_in ic;
    Some (Hasher.hash_string content)
  with _ -> None

let stat_kind path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> "dir"
  | exception _ -> "absent"
  | _ -> "file"

let stat_hash kind = Hasher.hash_string ("stat:" ^ kind)
let env_hash = function
  | Some value -> Hasher.hash_concat ["env-present"; value]
  | None -> Hasher.hash_concat ["env-absent"]
let argv_hash argv = Hasher.hash_concat ("argv" :: argv)

let tree_hash root =
  let entries = ref [] in
  let add rel part = entries := (rel ^ "=" ^ part) :: !entries in
  Fswalk.walk ~root ~cb:(fun ~rel ~path visit ->
    match visit with
    | Fswalk.Lstat_failed -> add rel (if rel = "" then "missing" else "unstattable")
    | Fswalk.Readdir_failed -> add rel "unreadable-dir"
    | Fswalk.Entry st ->
        if rel = "" then
          (match st.Unix.st_kind with
           | Unix.S_DIR -> ()
           | _ -> add "" (Option.value ~default:"unreadable" (hash_file root)))
        else
          match st.Unix.st_kind with
          | Unix.S_DIR -> ()
          | Unix.S_REG -> add rel (Option.value ~default:"unreadable" (hash_file path))
          | Unix.S_LNK -> add rel ("link->" ^ (try Unix.readlink path with _ -> "?"))
          | _ -> add rel "special");
  Hasher.hash_concat ("tree" :: List.sort compare !entries)

let call session fn args =
  match fn with
  | VClosure c when List.length c.params <> List.length args ->
      failwith "observer function arity mismatch"
  | VClosure _ | VBuiltin _ ->
      (Session.core_operations session).apply fn args (Session.current_env session)
  | _ -> failwith "observer is not a function"

let without_nested_observations cap f =
  try f () with
  | effect (Dynamic_scope.Record_read _), k -> Effect.Deep.continue k ()
  | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k false
  | effect Dynamic_scope.Get_capabilities, k -> Effect.Deep.continue k [cap]

let probe_value name =
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_probe session name with
  | Some value -> Some value
  | None ->
      (match Session.find_domain session name with
       | None -> None
       | Some entry ->
           let value = without_nested_observations entry.Session.dm_cap (fun () ->
             call session entry.Session.dm_observe []) in
           Session.set_probe session name value;
           Some value)

let observe_domain name sub =
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_domain session name with
  | None | Some { Session.dm_observe_cell = None; _ } -> None
  | Some { Session.dm_observe_cell = Some fn; dm_cap; _ } ->
      match without_nested_observations dm_cap (fun () -> call session fn [VString sub]) with
      | VNil -> None
      | VString hash -> Some hash
      | value -> Some (Identity.hash_value value)

let observe cell =
  let session = Effect.perform Dynamic_scope.Get_session in
  match cell with
  | Cell.File path ->
      (match Session.find_run_pin session (Cell.serialize cell) with
       | Some hash -> Some hash | None -> hash_file path)
  | Cell.RuntimeFile path | Cell.Tool path -> hash_file path
  | Cell.Tree root -> (try Some (tree_hash root) with _ -> None)
  | Cell.Stat path -> Some (stat_hash (stat_kind path))
  | Cell.Env name -> Some (env_hash (Sys.getenv_opt name))
  | Cell.Argv -> Some (argv_hash (Invocation.program_argv (Effect.perform Dynamic_scope.Get_invocation)))
  | Cell.Config key -> (try Some (Dynamic_scope.observe_config key) with _ -> None)
  | Cell.Handler name -> (try Some (Dynamic_scope.observe_handler name) with _ -> None)
  | Cell.Probe name -> Option.map Identity.hash_value (probe_value name)
  | Cell.Sealed path ->
      (match Session.find_sealed_pin session (Cell.serialize cell) with
       | Some bytes -> Some (Hasher.hash_string bytes) | None -> hash_file path)
  | Cell.Domain { name; sub } -> (try observe_domain name sub with _ -> None)
  | Cell.Unknown _ -> None

let observe_id (id : Identity_types.Cell_id.t) =
  Option.map Identity_types.Observed_hash.of_digest
    (observe (Cell.parse (Identity_types.Cell_id.to_string id)))
let record cell hash = Dynamic_scope.record_read (Cell.serialize cell) hash
let record_config key = record (Cell.Config key) (Dynamic_scope.observe_config key)
let record_handler name = record (Cell.Handler name) (Dynamic_scope.observe_handler name)
let replay reads =
  List.iter (fun (id, hash) ->
    record (Cell.parse (Identity_types.Cell_id.to_string id))
      (Identity_types.Observed_hash.to_string hash)) reads

let authorized caps cell =
  let has_fs path =
    List.exists (fun cap -> Capability.check_fs_read cap
      (Paths.canonicalize ~realpath:(fun x -> x) path)) caps
  in
  match cell with
  | Cell.File path | Cell.Tree path | Cell.Stat path -> has_fs path
  | Cell.Tool _ -> List.exists Capability.check_process caps
  | Cell.Sealed path ->
      List.exists (fun cap -> Capability.check_secret cap
        (Paths.canonicalize ~realpath:(fun x -> x) path)) caps
  | Cell.Domain { name; _ } ->
      (match Session.find_domain (Effect.perform Dynamic_scope.Get_session) name with
       | Some entry -> Capability.subseteq entry.Session.dm_cap caps | None -> false)
  | Cell.RuntimeFile _ | Cell.Env _ | Cell.Argv | Cell.Config _ | Cell.Handler _
  | Cell.Probe _ -> true
  | Cell.Unknown _ -> false

let authorized_id caps (id : Identity_types.Cell_id.t) =
  authorized caps (Cell.parse (Identity_types.Cell_id.to_string id))
