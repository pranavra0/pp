open Pp_kernel
open Core_model
open Source_error

let canonical path = (World_path.canonical path :> string)
let file path = Cell.File (canonical path)
let stat path = Cell.Stat (canonical path)
let sealed path = Cell.Sealed (canonical path)
let tool path = Cell.Tool (canonical path)
let tree path = Cell.Tree (canonical path)

let record cell hash = Dynamic_scope.record_read (Cell.serialize cell) hash
let node id = Cell.Node id

let hash_file path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (Hasher.hash_string
        (really_input_string ic (in_channel_length ic))))
  with Sys_error _ | Unix.Unix_error _ | End_of_file -> None

let stat_kind path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> "dir"
  | exception (Sys_error _ | Unix.Unix_error _) -> "absent"
  | _ -> "file"

let stat_hash kind = Hasher.hash_string ("stat:" ^ kind)
let env_hash = function
  | Some value -> Hasher.hash_concat ["env-present"; value]
  | None -> Hasher.hash_concat ["env-absent"]
let argv_hash argv = Hasher.hash_concat ("argv" :: argv)

let tree_snapshot root =
  let entries = ref [] in
  let files = ref [] in
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
          | Unix.S_REG ->
              let hash = Option.value ~default:"unreadable" (hash_file path) in
              add rel hash;
              files := (rel, hash) :: !files
          | Unix.S_LNK ->
              add rel ("link->" ^
                (try Unix.readlink path
                 with Sys_error _ | Unix.Unix_error _ -> "?"))
          | _ -> add rel "special");
  Hasher.hash_concat ("tree" :: List.sort compare !entries), !files

let tree_hash root = fst (tree_snapshot root)

let call session fn args =
  match fn with
  | VClosure c when List.length c.params <> List.length args ->
      failwith "observer function arity mismatch"
  | VClosure _ | VBuiltin _ ->
      Session.call session ~env:Environment.empty fn args
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

let read_file_cell path =
  let cell = file path in
  let serialized = Cell.serialize cell in
  let serve content hash =
    record cell hash;
    content
  in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_run_pin session serialized with
  | Some hash ->
      (match Blob_repository.get Blob_repository.default hash with
       | Some content -> serve content hash
       | None ->
           let content =
             match Store_layout.read path with
             | Some content -> content
             | None ->
                 raise
                   (Error
                      (Store
                         (Read_failed
                            { path; message = "file is missing or unreadable" })))
           in
           let hash = Blob_repository.put Blob_repository.default content in
           Session.set_run_pin session serialized hash;
           serve content hash)
  | None ->
      let content =
        match Store_layout.read path with
        | Some content -> content
        | None ->
            raise
              (Error
                 (Store
                    (Read_failed
                       { path; message = "file is missing or unreadable" })))
      in
      let hash = Blob_repository.put Blob_repository.default content in
      Session.set_run_pin session serialized hash;
      serve content hash

let read_sealed_cell path =
  let cell = sealed path in
  let serialized = Cell.serialize cell in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_sealed_pin session serialized with
  | Some bytes ->
      record cell (Hasher.hash_string bytes);
      bytes
  | None ->
      let bytes =
        match Store_layout.read path with
        | Some content -> content
        | None ->
            raise
              (Error
                 (Store
                    (Read_failed
                       { path; message = "file is missing or unreadable" })))
      in
      Session.set_sealed_pin session serialized bytes;
      record cell (Hasher.hash_string bytes);
      bytes

let require_fs_read head path =
  let canonical_path = World_path.canonical path in
  if
    not
      (List.exists
         (fun capability -> Capability.check_fs_read capability canonical_path)
         (Effect.perform Dynamic_scope.Get_capabilities))
  then
    capability
      (Printf.sprintf "$%s: filesystem read not granted: %s" head path);
  (canonical_path :> string)

let read_file path =
  match Sandbox.resolve ~create:false path with
  | Some scratch ->
      (match Store_layout.read scratch with
       | Some content -> VString content
       | None -> failwith ("$file: file is missing or unreadable: " ^ path))
  | None ->
      let canonical_path = World_path.canonical path in
      let capabilities = Effect.perform Dynamic_scope.Get_capabilities in
      if List.exists (fun cap -> Capability.check_fs_read cap canonical_path) capabilities then
        VString (read_file_cell (canonical_path :> string))
      else if List.exists (fun cap -> Capability.check_secret cap canonical_path) capabilities then
        VSealed (read_sealed_cell (canonical_path :> string))
      else
        capability
          (Printf.sprintf "$file: filesystem or secret read not granted: %s" path)

let read_secret path =
  let canonical_path = World_path.canonical path in
  if
    not
      (List.exists
         (fun capability -> Capability.check_secret capability canonical_path)
         (Effect.perform Dynamic_scope.Get_capabilities))
  then
    capability (Printf.sprintf "$secret: secret read not granted: %s" path);
  VSealed (read_sealed_cell (canonical_path :> string))

let read_tree path =
  let canonical_path = require_fs_read "tree" path in
  let hash, files =
    try tree_snapshot canonical_path
    with Sys_error message | Unix.Unix_error (_, _, message) ->
      failwith ("$tree: " ^ message)
  in
  record (Cell.Tree canonical_path) hash;
  Value.map
    (List.map
       (fun (relative_path, content_hash) ->
         VString relative_path, VString content_hash)
       files)

let read_stat path =
  let canonical_path = require_fs_read "stat" path in
  let kind = stat_kind canonical_path in
  record (Cell.Stat canonical_path) (stat_hash kind);
  match kind with
  | "file" -> VKeyword "file"
  | "dir" -> VKeyword "directory"
  | "absent" -> VNil
  | _ -> assert false

let read_argv () =
  let arguments =
    Invocation.program_argv (Effect.perform Dynamic_scope.Get_invocation)
  in
  record Cell.Argv (argv_hash arguments);
  List.fold_right (fun argument tail -> VPair (VString argument, tail)) arguments VNil

let read_env name =
  let value = Sys.getenv_opt name in
  record (Cell.Env name) (env_hash value);
  Option.map (fun contents -> VString contents) value

let read_probe name =
  match probe_value name with
  | None -> None
  | Some value ->
      record (Cell.Probe name) (Identity.hash_value value);
      Some value

let read_config key =
  record (Cell.Config key) (Dynamic_scope.observe_config key);
  Dynamic_scope.config_lookup key

let observe_domain name sub =
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_domain session name with
  | None | Some { Session.dm_observe_cell = None; _ } -> None
  | Some { Session.dm_observe_cell = Some fn; dm_cap; _ } ->
      match without_nested_observations dm_cap (fun () -> call session fn [VString sub]) with
      | VNil -> None
      | VString hash -> Some hash
      | value -> Some (Identity.hash_value value)

module KeySet = Set.Make (String)

let rec current_node_trace seen key =
  if KeySet.mem key seen then None
  else
    let session = Effect.perform Dynamic_scope.Get_session in
    let current_key = Option.value ~default:key
      (Option.map Identity_types.Node_key.to_string (Session.node_key_by_id session key)) in
    let seen = KeySet.add current_key (KeySet.add key seen) in
    let cache_key = Identity_types.Cache_key.of_string current_key in
    let valid trace =
      trace.Trace_repository.outcome = Trace_repository.Ok
      && List.for_all (fun (cell, expected) ->
           match observe_seen seen (Cell.parse (Identity_types.Cell_id.to_string cell)) with
           | Some current ->
               Identity_types.Observed_hash.of_digest current = expected
           | None -> false)
           trace.Trace_repository.reads
    in
    List.find_opt valid (Trace_repository.load Trace_repository.default ~key:cache_key)

and current_node_hash seen key =
  let session = Effect.perform Dynamic_scope.Get_session in
  let force_thunk current_key =
    match Session.find_node_thunk session current_key with
    | Some thunk ->
        (try Some (Identity.hash_value (Session.force session (VThunk thunk)))
         with _ -> None)
    | None -> None
  in
  match force_thunk (Identity_types.Node_key.of_string key) with
  | Some hash -> Some hash
  | None ->
      (match Session.node_key_by_id session key with
       | Some current_key -> force_thunk current_key
       | None ->
           Option.map (fun trace ->
             Identity_types.Object_hash.to_string trace.Trace_repository.result_hash)
             (current_node_trace seen key))

and observe_seen seen cell =
  let session = Effect.perform Dynamic_scope.Get_session in
  match cell with
  | Cell.File path ->
      (match Session.find_run_pin session (Cell.serialize cell) with
       | Some hash -> Some hash | None -> hash_file path)
  | Cell.RuntimeFile path | Cell.Tool path -> hash_file path
  | Cell.Tree root ->
      (try Some (tree_hash root)
       with Sys_error _ | Unix.Unix_error _ -> None)
  | Cell.Stat path -> Some (stat_hash (stat_kind path))
  | Cell.Env name -> Some (env_hash (Sys.getenv_opt name))
  | Cell.Argv -> Some (argv_hash (Invocation.program_argv (Effect.perform Dynamic_scope.Get_invocation)))
  | Cell.Config key -> Some (Dynamic_scope.observe_config key)
  | Cell.Handler name -> Some (Dynamic_scope.observe_handler name)
  | Cell.Probe name -> Option.map Identity.hash_value (probe_value name)
  | Cell.Sealed path ->
      (match Session.find_sealed_pin session (Cell.serialize cell) with
       | Some bytes -> Some (Hasher.hash_string bytes) | None -> hash_file path)
  | Cell.Node key -> current_node_hash seen key
  | Cell.Domain { name; sub } -> observe_domain name sub
  | Cell.Unknown _ -> None

let observe cell = observe_seen KeySet.empty cell

let observe_id (id : Identity_types.Cell_id.t) =
  Option.map Identity_types.Observed_hash.of_digest
    (observe (Cell.parse (Identity_types.Cell_id.to_string id)))
let record_config key = record (Cell.Config key) (Dynamic_scope.observe_config key)
let record_handler name = record (Cell.Handler name) (Dynamic_scope.observe_handler name)
let replay reads =
  List.iter (fun (id, hash) ->
    record (Cell.parse (Identity_types.Cell_id.to_string id))
      (Identity_types.Observed_hash.to_string hash)) reads

let rec authorized_seen seen caps cell =
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
  | Cell.Node key ->
      if KeySet.mem key seen then false
      else
        let session = Effect.perform Dynamic_scope.Get_session in
        let current_key = Option.value ~default:key
          (Option.map Identity_types.Node_key.to_string
             (Session.node_key_by_id session key))
        in
        let traces = Trace_repository.load Trace_repository.default
          ~key:(Identity_types.Cache_key.of_string current_key)
        in
        let seen = KeySet.add current_key (KeySet.add key seen) in
        traces <> []
        && List.for_all (fun trace ->
             List.for_all (fun (cell, _) ->
               authorized_seen seen caps
                 (Cell.parse (Identity_types.Cell_id.to_string cell)))
               trace.Trace_repository.reads)
             traces
  | Cell.Domain { name; _ } ->
      (match Session.find_domain (Effect.perform Dynamic_scope.Get_session) name with
       | Some entry -> Capability.subseteq entry.Session.dm_cap caps | None -> false)
  | Cell.RuntimeFile _ | Cell.Env _ | Cell.Argv | Cell.Config _ | Cell.Handler _
  | Cell.Probe _ -> true
  | Cell.Unknown _ -> false

let authorized caps cell = authorized_seen KeySet.empty caps cell

let authorized_id caps (id : Identity_types.Cell_id.t) =
  authorized caps (Cell.parse (Identity_types.Cell_id.to_string id))
