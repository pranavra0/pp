open Pp_kernel
open Core_model

type application = value -> value list -> env -> value

let has_fs_write path =
  List.exists
    (fun cap ->
      Capability.check_fs_write cap (World_path.canonical path))
    (Effect.perform Dynamic_scope.Get_capabilities)

let builtin name args =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           Process.read_dispatch ~tag:"read-file"
             ~cap_err:(fun p -> "read-file: capability error: no read access for " ^ p) path
       | _ -> failwith "read-file expects a string path")
  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           Process.write_file_effect ~has_cap:has_fs_write path content
       | _ -> failwith "write-file expects path and content strings")
  | "run" -> Process.run_effect args
  | "run-dep!" -> Process.run_dep_effect args
  | "http-get" ->
      (match args with
       | [VString url] -> Process.http_request ~method_:"GET" ~url ~body:None
       | _ -> failwith "http-get expects a url string")
  | "http-post" ->
      (match args with
       | [VString url; VString body] ->
           Process.http_request ~method_:"POST" ~url ~body:(Some body)
       | _ -> failwith "http-post expects a url string and a body string")
  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg;
           VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg;
           VNil
       | _ -> failwith "log expects a message string")
  | "tree-observe" ->
      (match args with
       | [VString root] -> Domain_prims.tree_observe root
       | _ -> failwith "tree-observe expects a root path string")
  | "materialize-file" ->
      (match args with
       | [VString path; VString content] ->
           Domain_prims.materialize_file path content false;
           VNil
       | [VString path; VString content; VKeyword "executable"] ->
           Domain_prims.materialize_file path content true;
           VNil
       | _ -> failwith "materialize-file expects a path, content, and optional :executable")
  | "remove-file" ->
      (match args with
       | [VString path] -> Domain_prims.remove_file path; VNil
       | _ -> failwith "remove-file expects a path string")
  | "proc-spawn" ->
      (match args with
       | [spec] -> Domain_prims.proc_spawn spec
       | _ -> failwith "proc-spawn expects a spec map")
  | "proc-alive?" ->
      (match args with
       | [VInt pid] -> VBool (Domain_prims.proc_alive pid)
       | _ -> failwith "proc-alive? expects a pid integer")
  | "proc-stop" ->
      (match args with
       | [VString name; VInt pid] -> Domain_prims.proc_stop name pid; VNil
       | _ -> failwith "proc-stop expects a service name and a pid integer")
  | "proc-reap" ->
      (match args with
       | [] -> Domain_prims.proc_reap (); VNil
       | _ -> failwith "proc-reap takes no arguments")
  | "domain-state-get" ->
      (match args with
       | [VString key] -> Domain_prims.domain_state_get key
       | _ -> failwith "domain-state-get expects a key string")
  | "domain-state-put" ->
      (match args with
       | [VString key; value] -> Domain_prims.domain_state_put key value; VNil
       | _ -> failwith "domain-state-put expects a key string and a value")
  | _ -> failwith ("unhandled effect: " ^ name)

let perform ~application name args =
  Observation.record_handler name;
  match Effect.perform (Dynamic_scope.Lookup_handler name) with
  | Some (handler, _) -> handler args
  | None -> builtin name args
