(* pp process-domain reconciler (Phase 2, LAW 30 / Q4).

   The program returns a desired-state value — a map of service-name → spec.
   The supervisor is the single writer for the process domain: it diffs
   desired specs against observed reality (running PIDs + their spec hashes),
   starts missing services, stops removed ones, and restarts services whose
   spec hash changed or whose process died.

   Process state is kept in ~/.pp/store/procs/<service-hash> (name, PID, spec
   hash, start time). Crash recovery is re-observation + re-reconcile, not
   replay of a trusted state file (Q4). Every start/stop is journaled
   intent/done.

   Authority: --grant process (CapProcess) is required. *)

open Types

let procs_dir = Filename.concat Store.store_root "procs"

let ensure_procs_dir () = Store.ensure_dir procs_dir

(* Service names are user-provided strings; hash them for a safe filename. *)
let state_file name =
  ensure_procs_dir ();
  Filename.concat procs_dir ("svc-" ^ Hasher.hash_string name)

let out_file name = Filename.concat procs_dir ("svc-" ^ Hasher.hash_string name ^ ".out")
let err_file name = Filename.concat procs_dir ("svc-" ^ Hasher.hash_string name ^ ".err")

type proc_state = {
  name : string;
  pid : int;
  spec_hash : string;
  start_time : float;
}

let stopped_hash = Hasher.hash_string "proc:stopped"

let validate_name name =
  if name = "" then failwith "supervise: empty service name";
  if String.contains name '/' then
    failwith ("supervise: service name may not contain '/': " ^ name);
  if String.contains name '\\' then
    failwith ("supervise: service name may not contain '\\': " ^ name)

let has_process_cap () =
  List.exists (function CapProcess -> true | _ -> false)
    !Runtime.current_capabilities

(* ---- Desired-spec parsing ---- *)

(* Deref at call time: the hook is installed by Evaluator.init/Vm.init AFTER
   this module loads — a module-init-time deref would freeze the identity
   default forever. *)
let force v = !Runtime.force_hook v

let rec force_deep v =
  match force v with
  | VPair (a, d) -> VPair (force_deep a, force_deep d)
  | VVector vs -> VVector (Array.map force_deep vs)
  | VMap kvs -> VMap (List.map (fun (k, v) -> (force_deep k, force_deep v)) kvs)
  | VSet vs -> VSet (List.map force_deep vs)
  | other -> other

let expect_string where v =
  match force v with
  | VString s -> s
  | VKeyword s | VSymbol s -> s
  | other -> failwith (Printf.sprintf "supervise: %s must be a string, got %s"
                         where (string_of_value other))

let expect_strings where v =
  let rec collect = function
    | VNil -> []
    | VPair (a, d) -> expect_string where a :: collect d
    | VVector arr -> Array.to_list (Array.map (expect_string where) arr)
    | other -> failwith (Printf.sprintf "supervise: %s must be a list or vector of strings, got %s"
                           where (string_of_value other))
  in
  collect (force v)

let expect_env where v =
  let v = force v in
  match v with
  | VMap kvs ->
      List.map (fun (k, v) ->
        let key = expect_string (where ^ " env key") k in
        let value = expect_string (where ^ " env value") v in
        (key, value)) kvs
  | VNil -> []
  | other -> failwith (Printf.sprintf "supervise: %s env must be a map, got %s"
                         where (string_of_value other))

type spec = {
  cmd : string;
  args : string list;
  env : (string * string) list;
  cwd : string;
  raw : value;  (* forced, for hashing *)
}

let parse_spec name spec_val =
  let spec_map =
    match force spec_val with
    | VMap kvs -> kvs
    | other -> failwith ("supervise: spec for " ^ name ^ " must be a map, got "
                         ^ string_of_value other)
  in
  let find key =
    List.find_opt (fun (k, _) ->
      match force k with VString s | VKeyword s | VSymbol s -> s = key | _ -> false)
      spec_map
  in
  let cmd =
    match find "cmd" with
    | Some (_, v) -> expect_string ("service " ^ name ^ " cmd") v
    | None -> failwith ("supervise: service " ^ name ^ " missing 'cmd'")
  in
  let args =
    match find "args" with
    | Some (_, v) -> expect_strings ("service " ^ name ^ " args") v
    | None -> []
  in
  let env =
    match find "env" with
    | Some (_, v) -> expect_env ("service " ^ name) v
    | None -> []
  in
  let cwd =
    match find "cwd" with
    | Some (_, v) -> expect_string ("service " ^ name ^ " cwd") v
    | None -> Sys.getcwd ()
  in
  (* Build a fully forced canonical value for hashing. *)
  let forced_pairs =
    List.map (fun (k, v) -> (force_deep k, force_deep v)) spec_map
  in
  { cmd; args; env; cwd; raw = VMap forced_pairs }

let parse_desired desired_val =
  let desired_map =
    match force desired_val with
    | VMap kvs -> kvs
    | other -> failwith ("supervise: the program must return a map of service names to specs, got "
                         ^ string_of_value other)
  in
  List.map (fun (k, v) ->
    let name = expect_string "service name" k in
    validate_name name;
    (name, parse_spec name v)) desired_map

let spec_hash spec = Hasher.hash_value spec.raw

(* ---- State file I/O ---- *)

let load_state name : proc_state option =
  let path = state_file name in
  if Sys.file_exists path then
    try
      let ic = open_in_bin path in
      let len = in_channel_length ic in
      let s = really_input_string ic len in
      close_in ic;
      let v = Marshal.from_bytes (Bytes.of_string s) 0 in
      Some v
    with _ -> None
  else
    None

let save_state st =
  ensure_procs_dir ();
  let path = state_file st.name in
  let bytes = Marshal.to_bytes st [] in
  Store.atomic_write path (Bytes.to_string bytes)

let remove_state name =
  let path = state_file name in
  if Sys.file_exists path then (try Sys.remove path with _ -> ());
  let o = out_file name in
  if Sys.file_exists o then (try Sys.remove o with _ -> ());
  let e = err_file name in
  if Sys.file_exists e then (try Sys.remove e with _ -> ())

(* ---- Process helpers ---- *)

let reap_children () =
  let rec loop () =
    try
      match Unix.waitpid [Unix.WNOHANG] (-1) with
      | 0, _ -> ()
      | _pid, _status -> loop ()
    with Unix.Unix_error _ -> ()
  in
  loop ()

let is_alive pid =
  try
    (* If [pid] is our child and a zombie, reap it so kill -0 reports the
       truth. If it is not our child, waitpid raises ECHILD and we ignore. *)
    (try ignore (Unix.waitpid [Unix.WNOHANG] pid) with Unix.Unix_error _ -> ());
    Unix.kill pid 0;
    true
  with Unix.Unix_error _ -> false

let stop_process pid =
  try
    Unix.kill pid Sys.sigterm;
    (* Wait up to 1s for graceful exit, then SIGKILL. *)
    let deadline = Unix.gettimeofday () +. 1.0 in
    let rec wait () =
      if not (is_alive pid) then ()
      else if Unix.gettimeofday () > deadline then
        (try Unix.kill pid Sys.sigkill with _ -> ())
      else (Unix.sleepf 0.05; wait ())
    in
    wait ()
  with Unix.Unix_error _ -> ()

let env_array spec_env =
  let base = Array.to_list (Unix.environment ()) in
  let overrides = List.map (fun (k, v) -> k ^ "=" ^ v) spec_env in
  Array.of_list (overrides @ base)

let start_service name spec : int =
  let resolved =
    match Process.resolve_cmd spec.cmd with
    | Some p -> p
    | None -> failwith ("supervise: command not found for service " ^ name ^ ": " ^ spec.cmd)
  in
  Journal.append (Journal.ProcStartIntent { name; spec_hash = spec_hash spec });
  let argv = resolved :: spec.args in
  let env = env_array spec.env in
  let out_f = out_file name in
  let err_f = err_file name in
  let pid =
    match Unix.fork () with
    | 0 ->
        (* Child: chdir, redirect stdio, exec. *)
        (try
           Unix.chdir spec.cwd;
           let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
           let fd_out = Unix.openfile out_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
           let fd_err = Unix.openfile err_f [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
           Unix.dup2 fd_in Unix.stdin;
           Unix.dup2 fd_out Unix.stdout;
           Unix.dup2 fd_err Unix.stderr;
           Unix.close fd_in;
           Unix.close fd_out;
           Unix.close fd_err;
           Unix.execve resolved (Array.of_list argv) env
         with _ -> Unix._exit 127)
    | pid -> pid
  in
  save_state { name; pid; spec_hash = spec_hash spec; start_time = Unix.gettimeofday () };
  Journal.append (Journal.ProcStartDone { name; spec_hash = spec_hash spec; pid });
  pid

let stop_service state =
  Journal.append (Journal.ProcStopIntent { name = state.name });
  stop_process state.pid;
  remove_state state.name;
  Journal.append (Journal.ProcStopDone { name = state.name })

(* ---- Cell observation hook ---- *)

let observe_proc (name : string) : string option =
  match load_state name with
  | Some state when is_alive state.pid -> Some state.spec_hash
  | _ -> Some stopped_hash

(* ---- Reconcile ---- *)

(* Enumerate all services recorded in the state directory. *)
let recorded_services () : proc_state list =
  if not (Sys.file_exists procs_dir) then []
  else
    Array.fold_left (fun acc fname ->
      if String.starts_with ~prefix:"svc-" fname && not (String.contains fname '.') then
        let path = Filename.concat procs_dir fname in
        try
          let ic = open_in_bin path in
          let len = in_channel_length ic in
          let s = really_input_string ic len in
          close_in ic;
          let state : proc_state = Marshal.from_bytes (Bytes.of_string s) 0 in
          state :: acc
        with _ -> acc
      else acc)
      [] (Sys.readdir procs_dir)

let reconcile (desired_val : value) : unit =
  if not (has_process_cap ()) then
    raise (Capability_error "capability error: no process authority for supervise");
  reap_children ();
  (* Stratification (LAW 30): desired process state may not read its own
     proc cells — otherwise reconcile loops forever. *)
  List.iter (fun (cell, _) ->
    match Cell.of_string cell with
    | Cell.Proc _ ->
        failwith ("supervise: stratification violation (LAW 30): the desired \
                   process state observed its own domain: " ^ cell)
    | _ -> ())
    !Runtime.observed_all;
  let desired = parse_desired desired_val in
  let desired_names = List.map fst desired in
  let started = ref 0 in
  let stopped = ref 0 in
  let restarted = ref 0 in
  (* Start new / restart changed-or-dead services. *)
  List.iter (fun (name, spec) ->
    match load_state name with
    | None ->
        let _pid = start_service name spec in
        incr started
    | Some state ->
        if not (is_alive state.pid) then begin
          stop_service state;
          let _pid = start_service name spec in
          incr restarted
        end else if state.spec_hash <> spec_hash spec then begin
          stop_service state;
          let _pid = start_service name spec in
          incr restarted
        end
  ) desired;
  (* Stop services that are recorded but no longer desired. *)
  List.iter (fun state ->
    if not (List.mem state.name desired_names) then begin
      stop_service state;
      incr stopped
    end)
    (recorded_services ());
  Printf.eprintf "[supervise] started=%d restarted=%d stopped=%d\n%!"
    !started !restarted !stopped
