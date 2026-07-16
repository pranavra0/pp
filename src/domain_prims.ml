(* pp domain primitives.

   A domain is an observe/diff/apply triple of ordinary pp functions
   (registered via `register-domain`) running under core-enforced discipline;
   these are the TRUSTED MECHANICS that used to live in reconciler.ml/
   supervisor.ml:
   atomic file materialization, fork/exec/reap, and domain-private state
   persistence. What is NOT here is policy — no tree-walk/diff decision, no
   start/stop/restart decision; those live in stdlib/domain-fs.pp and
   stdlib/domain-proc.pp as real pp source, calling these primitives via
   `perform`. Every primitive that writes is trace_stack-guarded out of node
   bodies (the LAW 31 fenced/write-file pattern) and capability-gated against
   the ambient `!Runtime.current_capabilities` — during a domain's own
   observe/apply, that ambient is exactly the domain's registered write-cap
   (Domains.with_domain / the with_ref current_capabilities [write_cap]
   threading), so these checks are the SAME mechanism `write-file`/`run`
   already use, not a new authority path. *)

open Types

let require_no_node_body (who : string) : unit =
  if Effect.perform Runtime.In_node then
    failwith (who ^ ": may not be called inside a node body (writes are domain-apply-only)")

let has_fs_read path =
  List.exists (fun cap -> Capability.check_fs_read cap (Runtime.canonical_path path))
    (Effect.perform Runtime.Get_capabilities)

let has_fs_write path =
  List.exists (fun cap -> Capability.check_fs_write cap (Runtime.canonical_path path))
    (Effect.perform Runtime.Get_capabilities)
(* Capabilities.check_process recurses through CapCompose (and so, via
   check_process's own CapCompose arm, through however many levels a
   domain's registered cap is typically exactly that round-trip (main.ml's
   glue registers the proc domain's write-cap as `(current-capabilities)`
   itself, a single CapCompose value, not narrowed the way fs's is via
   cap-restrict), so `current_capabilities` inside observe/apply is a
   ONE-ELEMENT list whose element is a CapCompose — a flat top-level
   `function CapProcess -> true | _ -> false` scan (as process.ml's
   has_process_cap did before it needed to recurse through CapCompose)
   would miss it. *)
let has_process_cap () =
  List.exists Capability.check_process (Effect.perform Runtime.Get_capabilities)

(* Fully force a value (map values / vector-set elements are lazy by
   construction, primitives.ml) so Codec.encode_value and Hasher.hash_value
   see actual leaves, not unevaluated thunks — the same shape as
   Fenced.force_deep / Primitives.force_deep, duplicated here for the same
   reason those two are already duplicated rather than shared (small, and
   each module's force_hook indirection is set up independently). *)

(* ---- tree-observe: {relpath -> content-hash}, fs-read-gated ----
   Moved from Reconciler.observed_files; returns a pp VMap instead of an
   assoc list (the diff runs in pp, over pp values) and canonicalizes root
   the same way every other fs boundary does (LAW 23 / DESIGN §2.1). *)
let tree_observe (root : string) : value =
  let root_canon = Runtime.canonical_path root in
  let root = (root_canon :> string) in
  (* A write-only domain grant (`fs:ROOT:wo`, tests/023) must still be able
     to observe its OWN managed tree — the single writer reading its own
     domain to converge is not a new authority concern (there is no other
     reader involved); the old OCaml reconciler's internal tree scan was
     never gated on read at all. Accepting EITHER read or write keeps this
     "capability-gated" (a grant with NEITHER is refused) without demanding
     authority a write-only domain was never meant to need. *)
  if not (has_fs_read root || has_fs_write root) then
    raise (Capability_error ("tree-observe: capability error: no read or write access for " ^ root));
  let acc = ref [] in
  if Sys.file_exists root && Sys.is_directory root then
    Fswalk.walk ~root ~cb:(fun ~rel ~path visit ->
      match visit with
      | Fswalk.Entry { Unix.st_kind = Unix.S_REG; _ } ->
          (match Store.hash_file_opt path with
           | Some h -> acc := (VString rel, VString h) :: !acc
           | None -> ())
      | _ -> ());
  VMap !acc

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    (try mkdir_p (Filename.dirname dir) with _ -> ());
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let materialize_file (path : string) (content : string) (executable : bool) : unit =
  require_no_node_body "materialize-file";
  let path_canon = Runtime.canonical_path path in
  let path = (path_canon :> string) in
  if not (has_fs_write path) then
    raise (Capability_error ("materialize-file: capability error: no write access for " ^ path));
  mkdir_p (Filename.dirname path);
  let tmp = path ^ ".pp-tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  (try output_string oc content
   with exn -> close_out oc; (try Sys.remove tmp with _ -> ()); raise exn);
  close_out oc;
  Unix.rename tmp path;
  if executable then (try Unix.chmod path 0o755 with _ -> ());
  Store.unpin_file path


let rec prune_empty_dirs (dir : string) : unit =
  if has_fs_write dir then
    match Sys.readdir dir with
    | [||] -> (try Unix.rmdir dir with _ -> ()); prune_empty_dirs (Filename.dirname dir)
    | _ -> ()
    | exception _ -> ()

let remove_file (path : string) : unit =
  require_no_node_body "remove-file";
  let path_canon = Runtime.canonical_path path in
  let path = (path_canon :> string) in
  if not (has_fs_write path) then
    raise (Capability_error ("remove-file: capability error: no write access for " ^ path));
  (try Sys.remove path with _ -> ());
  Store.unpin_file path;
  prune_empty_dirs (Filename.dirname path)


(* ---- domain-state-get/put: per-domain persistent KV, replacing procs/'s
   role ----
   Scoped implicitly to Runtime.current_domain ("core knows which domain is
   running" — set by Domains.with_domain for the extent of observe/diff/
   apply). Gated on cap_subseteq of the CURRENT domain's own registered cap
   against the ambient: during diff (which runs under a threaded EMPTY
   capability set, since diff must be pure) this can never hold (no
   capability is a subset of nothing unless it grants nothing), so diff
   calling domain-state-get/put
   is a Capability_error automatically — closing that side-channel with the
   SAME mechanism diff's purity already uses, not a new checker. *)
let require_domain_context (who : string) : Runtime.domain_entry * string =
  match Effect.perform Runtime.Get_domain with
  | None -> failwith (who ^ ": not running inside a domain's observe/diff/apply")
  | Some name ->
      (match Hashtbl.find_opt Runtime.domain_registry name with
       | None -> failwith (who ^ ": unknown current domain " ^ name)
       | Some entry ->
           if Capability.subseteq entry.Runtime.dm_cap (Effect.perform Runtime.Get_capabilities)
           then (entry, name)
           else raise (Capability_error
                    (who ^ ": capability error: no authority for domain " ^ name)))

let domain_state_root (domain_name : string) : string =
  Filename.concat Store.store_root (Filename.concat "domain-state" domain_name)

let state_key_file (domain_name : string) (key : string) : string =
  Filename.concat (domain_state_root domain_name) (Hasher.hash_string key)

let domain_state_get (key : string) : value =
  let (_, name) = require_domain_context "domain-state-get" in
  let path = state_key_file name key in
  if Sys.file_exists path then
    (try
       let ic = open_in_bin path in
       let s = really_input_string ic (in_channel_length ic) in
       close_in ic;
       match Codec.decode_value s with
       | Some v -> v
       | None -> VNil
     with _ -> VNil)
  else VNil

let domain_state_put (key : string) (v : value) : unit =
  let (_, name) = require_domain_context "domain-state-put" in
  let dir = domain_state_root name in
  let path = state_key_file name key in
  match v with
  | VNil -> if Sys.file_exists path then (try Sys.remove path with _ -> ())
  | _ ->
      Store.ensure_dir dir;
      let forced = Force_deep.force_deep_plain v in
      (match Codec.encode_value forced with
       | Some content -> Store.atomic_write path content
       | None -> failwith "domain-state-put: value is not serializable data")

(* ---- proc-spawn / proc-alive? / proc-stop / proc-reap ----
   Moved verbatim from supervisor.ml (fork/exec/stdio arm, TERM->poll->KILL,
   waitpid reaping); proc-spawn/proc-stop own their intent/done journal
   lines exactly as the old Supervisor did (Journal.ProcStart*/ProcStop*
   entries are untouched — only the fs-only per-pass FsIntent/FsDone bracket
   was generalized, journal.ml). *)

(* Field values in a spec map are lazy ("keys forced, values lazy" —
   primitives.ml's hash-map/map-insert): every lookup below forces the
   value via force_hook before matching. *)
let find_field kvs key =
  Option.map (fun (_, v) -> Backend.r.force v)
    (List.find_opt (fun (k', _) -> string_like k' = Some key) kvs)

let expect_string_field where kvs key =
  match find_field kvs key with
  | Some v -> (match string_like v with Some s -> s | None -> failwith (Printf.sprintf "%s: %s must be a string, got %s" where key (string_of_value v)))
  | None -> failwith (Printf.sprintf "%s: missing '%s'" where key)

let expect_opt_string_field where kvs key default_ =
  match find_field kvs key with
  | Some v -> (match string_like v with Some s -> s | None -> failwith (Printf.sprintf "%s: %s must be a string, got %s" where key (string_of_value v)))
  | None -> default_

let expect_string_list_field where kvs key =
  let one v = match string_like (Backend.r.force v) with Some s -> s | None -> failwith (Printf.sprintf "%s: %s elements must be strings, got %s" where key (string_of_value v)) in
  match find_field kvs key with
  | None | Some VNil -> []
  | Some (VVector arr) -> Array.to_list (Array.map one arr)
  | Some (VPair _ as lst) ->
      let rec collect = function
        | VNil -> []
        | VPair (a, d) -> one a :: collect (Backend.r.force d)
        | other -> failwith (Printf.sprintf "%s: %s must be a list/vector of strings, got %s"
                              where key (string_of_value other))
      in collect lst
  | Some other -> failwith (Printf.sprintf "%s: %s must be a list/vector of strings, got %s"
                              where key (string_of_value other))

let expect_env_field where kvs key =
  match find_field kvs key with
  | None | Some VNil -> []
  | Some (VMap envkvs) ->
      List.map (fun (k, v) ->
        let ks = match string_like (Backend.r.force k) with Some s -> s | None -> failwith (where ^ ": env key must be a string, got " ^ string_of_value k) in
        let vs = match string_like (Backend.r.force v) with Some s -> s | None -> failwith (where ^ ": env value must be a string, got " ^ string_of_value v) in
        (ks, vs))
        envkvs
  | Some other -> failwith (where ^ ": " ^ key ^ " must be a map, got " ^ string_of_value other)

let env_array spec_env =
  let base = Array.to_list (Unix.environment ()) in
  let overrides = List.map (fun (k, v) -> k ^ "=" ^ v) spec_env in
  Array.of_list (overrides @ base)

let domain_io_dir () : string =
  let name = match Effect.perform Runtime.Get_domain with Some n -> n | None -> "unknown" in
  Filename.concat Store.store_root (Filename.concat "domain-state" (name ^ "-io"))

let out_file name = Filename.concat (domain_io_dir ()) ("svc-" ^ Hasher.hash_string name ^ ".out")
let err_file name = Filename.concat (domain_io_dir ()) ("svc-" ^ Hasher.hash_string name ^ ".err")

let proc_spawn (spec : value) : value =
  require_no_node_body "proc-spawn";
  if not (has_process_cap ()) then
    raise (Capability_error "proc-spawn: capability error: no process authority");
  let kvs = match Backend.r.force spec with
    | VMap kvs -> kvs
    | other -> failwith ("proc-spawn: spec must be a map, got " ^ string_of_value other)
  in
  let name = expect_string_field "proc-spawn" kvs "name" in
  let cmd = expect_string_field "proc-spawn" kvs "cmd" in
  let args = expect_string_list_field "proc-spawn" kvs "args" in
  let env = expect_env_field "proc-spawn" kvs "env" in
  let cwd = expect_opt_string_field "proc-spawn" kvs "cwd" (Sys.getcwd ()) in
  let resolved = match Process.resolve_cmd cmd with
    | Some p -> p
    | None -> failwith ("proc-spawn: command not found for service " ^ name ^ ": " ^ cmd)
  in
  let spec_hash = Types.hash_value (Force_deep.force_deep_plain spec) in
  Journal.append (Journal.ProcStartIntent { name; spec_hash });
  Store.ensure_dir (domain_io_dir ());
  let argv = resolved :: args in
  let envp = env_array env in
  let out_f = out_file name in
  let err_f = err_file name in
  let pid =
    match Unix.fork () with
    | 0 ->
        (try
           Unix.chdir cwd;
           let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
           let fd_out = Unix.openfile out_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
           let fd_err = Unix.openfile err_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
           Unix.dup2 fd_in Unix.stdin;
           Unix.dup2 fd_out Unix.stdout;
           Unix.dup2 fd_err Unix.stderr;
           Unix.close fd_in; Unix.close fd_out; Unix.close fd_err;
           Unix.execve resolved (Array.of_list argv) envp
         with _ -> Unix._exit 127)
    | pid -> pid
  in
  Journal.append (Journal.ProcStartDone { name; spec_hash; pid });
  VInt pid

let is_alive (pid : int) : bool =
  try
    (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with Unix.Unix_error _ -> ());
    Unix.kill pid 0;
    true
  with Unix.Unix_error _ -> false

let proc_alive (pid : int) : bool =
  if not (has_process_cap ()) then
    raise (Capability_error "proc-alive?: capability error: no process authority");
  is_alive pid

(* (perform proc-stop name pid) — TERM, poll up to 1s, then KILL; owns its
   intent/done journal lines verbatim (moved from Supervisor.stop_service /
   stop_process). *)
let proc_stop (name : string) (pid : int) : unit =
  require_no_node_body "proc-stop";
  if not (has_process_cap ()) then
    raise (Capability_error "proc-stop: capability error: no process authority");
  Journal.append (Journal.ProcStopIntent { name });
  (try
     Unix.kill pid Sys.sigterm;
     let deadline = Unix.gettimeofday () +. 1.0 in
     let rec wait () =
       if not (is_alive pid) then ()
       else if Unix.gettimeofday () > deadline then
         (try Unix.kill pid Sys.sigkill with _ -> ())
       else (Unix.sleepf 0.05; wait ())
     in
     wait ()
   with Unix.Unix_error _ -> ());
  let o = out_file name and e = err_file name in
  (try Sys.remove o with _ -> ());
  (try Sys.remove e with _ -> ());
  Journal.append (Journal.ProcStopDone { name })

(* (perform proc-reap) — reap zombie children; the supervisor tracks only
   its OWN spawned pids (no OS process enumeration). *)
let proc_reap () : unit =
  require_no_node_body "proc-reap";
  let rec loop () =
    try
      match Unix.waitpid [Unix.WNOHANG] (-1) with
      | 0, _ -> ()
      | _pid, _status -> loop ()
    with Unix.Unix_error _ -> ()
  in
  loop ()
