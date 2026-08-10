open Pp_kernel
(* Scheduler placement for persistent-node jobs. A job carries identity and
   placement metadata; the caller supplies the runner for local execution.
   Serial execution is the reference adapter. Process and remote adapters
   use the store as their result channel and fall back to the caller's
   ordinary miss path when a worker does not produce a hit. *)
type policy = Serial | Parallel of int | Race of int | Remote of string

type batch_mode = Serial_batch | Parallel_batch of int | Race_batch of int
  | Remote_batch of string
type custom_plan = { mode : batch_mode; batches : int list list }

type job = {
  j_key : Identity_types.Node_key.t;
  j_width : int;
  j_data_closed : bool;
}
type runner = job -> unit
type handler = {
  h_name : string;
  h_redundancy : int;
  h_dispatch : t -> runner -> job list -> unit;
  h_cancel : unit -> unit;
}
and t = {
  mutable handler : handler;
  live_children : (int, Identity_types.Node_key.t) Hashtbl.t;
  mutable signal_handler : Sys.signal_behavior option;
  mutable fork_count : int;
  fork_log_path : string option;
}

let handler ~name ~redundancy ~dispatch ~cancel = {
  h_name = name;
  h_redundancy = max 1 redundancy;
  h_dispatch = (fun _ run jobs -> dispatch run jobs);
  h_cancel = cancel;
}

let handler_name handler = handler.h_name

let serial_handler = handler ~name:"serial" ~redundancy:1
    ~dispatch:(fun run jobs -> List.iter run jobs)
    ~cancel:ignore
let serial = serial_handler

(* ---- Live-child bookkeeping (for SIGINT and race-loser kills) ---- *)

let kill_grace_seconds = 0.5

(* Best-effort: SIGTERM, wait a short grace period (polling with a
   non-blocking waitpid — we must not block the parent indefinitely on a
   wedged child), SIGKILL if still alive, then reap. Never raises: a
   process that already exited between our checks is not an error here. *)
let terminate_pid (pid : int) : unit =
  (try Unix.kill pid Sys.sigterm with _ -> ());
  let deadline = Unix.gettimeofday () +. kill_grace_seconds in
  let rec wait_dead () =
    if Unix.gettimeofday () > deadline then ()
    else
      match (try Some (Unix.waitpid [Unix.WNOHANG] pid) with
             | Unix.Unix_error (Unix.ECHILD, _, _) -> None) with
      | Some (0, _) -> Unix.sleepf 0.02; wait_dead ()
      | Some (_, _) -> ()
      | None -> ()
  in
  wait_dead ();
  (try Unix.kill pid Sys.sigkill with _ -> ());
  (try ignore (Unix.waitpid [] pid) with _ -> ())

(* Best-effort cleanup of a dead/killed child's sandbox scratch dirs. A
   node's sandbox is named "pp-sandbox-<pid>-<n>" under the system temp dir
   (Sandbox.current) and is normally removed by the child itself
   when its trace frame pops — this is a belt-and-suspenders sweep for the
   case where the child was killed (race loser) or died before its own
   cleanup ran. The parent doesn't know which counters a child used, so it
   globs by pid prefix; a child that never touched scratch leaves nothing
   to remove, and the glob is scoped to this pid so it cannot touch a
   sibling's live sandbox. *)
let cleanup_child_sandboxes (pid : int) : unit =
  let tmp = Filename.get_temp_dir_name () in
  try
    let prefix = Printf.sprintf "pp-sandbox-%d-" pid in
    let plen = String.length prefix in
    Array.iter (fun name ->
      if String.length name >= plen && String.sub name 0 plen = prefix then
        Fswalk.remove_tree (Filename.concat tmp name))
      (Sys.readdir tmp)
  with _ -> ()

let reap_and_cleanup (scheduler : t) (pid : int) : unit =
  Hashtbl.remove scheduler.live_children pid;
  cleanup_child_sandboxes pid

let kill_all_live (scheduler : t) =
  scheduler.handler.h_cancel ();
  let pids = Hashtbl.fold (fun pid _ acc -> pid :: acc)
      scheduler.live_children [] in
  List.iter (fun pid -> terminate_pid pid; reap_and_cleanup scheduler pid) pids

let install_signal_handler (scheduler : t) =
  match scheduler.signal_handler with
  | Some _ -> ()
  | None ->
      let previous = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
        kill_all_live scheduler;
        exit 130)) in
      scheduler.signal_handler <- Some previous

let restore_signal_handler (scheduler : t) =
  match scheduler.signal_handler with
  | None -> ()
  | Some previous ->
      Sys.set_signal Sys.sigint previous;
      scheduler.signal_handler <- None

let with_signal_handler scheduler ~f x =
  install_signal_handler scheduler;
  Fun.protect
    ~finally:(fun () ->
      kill_all_live scheduler;
      restore_signal_handler scheduler)
    (fun () -> f x)

(* ---- fork/exec-free "exec" of one job in a child ---- *)

(* Unflushed stdio buffers are duplicated across fork() (each process then
   flushes its own copy, printing the parent's pending output twice) — flush
   both channels in the PARENT immediately before every fork. *)
let flush_before_fork () =
  (try flush stdout with _ -> ());
  (try flush stderr with _ -> ())

let run_child (run : runner) (j : job) : unit =
  let status = try run j; 0 with _ -> 1 in
  (try flush stdout with _ -> ());
  (try flush stderr with _ -> ());
  Unix._exit status

(* The fork adapter records fan-out when PP_FORK_LOG is enabled. *)
let fork_job (scheduler : t) (run : runner) (j : job) : int =
  flush_before_fork ();
  match Unix.fork () with
  | 0 -> run_child run j; Unix._exit 1
  | pid ->
      scheduler.fork_count <- scheduler.fork_count + 1;
      (match scheduler.fork_log_path with
       | Some p ->
           (try
              let fd = Unix.openfile p [Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT] 0o644 in
              ignore (Unix.write_substring fd "fork\n" 0 5); Unix.close fd
            with _ -> ())
       | None -> ());
      Hashtbl.replace scheduler.live_children pid j.j_key; pid

(* Run a bounded wave of local jobs. Race redundancy reuses the same key;
   the first successful worker wins and remaining workers for that key stop. *)
let run_concurrent (scheduler : t) (run : runner)
    (limit : int) (jobs : job list) : unit =
  let limit = max 1 limit in
  let queue = Queue.create () in
  List.iter (fun j -> for _ = 1 to max 1 j.j_width do Queue.push j queue done) jobs;
  let succeeded_keys : (Identity_types.Node_key.t, unit) Hashtbl.t = Hashtbl.create 16 in
  let live_count = ref 0 in
  let kill_losers_for (key : Identity_types.Node_key.t) : unit =
    let losers =
        Hashtbl.fold (fun p k acc -> if k = key then p :: acc else acc)
        scheduler.live_children []
    in
    List.iter (fun p ->
      terminate_pid p;
      reap_and_cleanup scheduler p;
      decr live_count)
      losers
  in
  (* Wait for exactly one of OUR children; a pid this dispatch didn't fork
     (there shouldn't be any — pp's own subprocess effects wait
     synchronously — but be defensive) is reaped and ignored so we never
     spin forever on a stray SIGCHLD. *)
  let rec reap_one () =
    match (try Some (Unix.wait ()) with Unix.Unix_error (Unix.ECHILD, _, _) -> None) with
    | None -> live_count := 0
    | Some (pid, status) ->
        if not (Hashtbl.mem scheduler.live_children pid) then reap_one ()
        else begin
          let key = Hashtbl.find scheduler.live_children pid in
          reap_and_cleanup scheduler pid;
          decr live_count;
          let ok = match status with Unix.WEXITED 0 -> true | _ -> false in
          if ok && not (Hashtbl.mem succeeded_keys key) then begin
            Hashtbl.replace succeeded_keys key ();
            kill_losers_for key
          end
        end
  in
  while not (Queue.is_empty queue) || !live_count > 0 do
    while !live_count < limit && not (Queue.is_empty queue) do
      let j = Queue.pop queue in
      if Hashtbl.mem succeeded_keys j.j_key then ()
        (* a duplicate of an already-won race: never fork it *)
      else begin
        ignore (fork_job scheduler run j);
        incr live_count
      end
    done;
    if !live_count > 0 then reap_one ()
  done

let custom ~name ~redundancy
    ~(remote_dispatch : member:string -> job list -> unit)
    ~(plan : job list -> custom_plan) =
  let run_batch scheduler run mode jobs =
    match mode with
    | Serial_batch -> List.iter run jobs
    | Parallel_batch width -> run_concurrent scheduler run width jobs
    | Race_batch width -> run_concurrent scheduler run width jobs
    | Remote_batch member -> remote_dispatch ~member jobs
  in
  { h_name = name;
    h_redundancy = max 1 redundancy;
    h_dispatch = (fun scheduler run jobs ->
      let indexes = List.mapi (fun index _ -> index) jobs in
      let plan = plan jobs in
      let selected = List.concat plan.batches in
      let valid_index index = index >= 0 && index < List.length jobs in
      if List.exists (fun index -> not (valid_index index)) selected then
        failwith "scheduler: custom plan contains an out-of-range job index";
      let sorted = List.sort compare selected in
      if sorted <> indexes then
        failwith "scheduler: custom plan must schedule every job exactly once";
      List.iter (fun batch ->
        let batch_jobs = List.map (fun index -> List.nth jobs index) batch in
        run_batch scheduler run plan.mode batch_jobs)
        plan.batches);
    h_cancel = ignore }

let builtin ~remote_dispatch = function
  | Serial -> serial_handler
  | Parallel n -> { serial_handler with
      h_name = Printf.sprintf "parallel:%d" n;
      h_dispatch = (fun scheduler run jobs -> run_concurrent scheduler run n jobs) }
  | Race n -> { serial_handler with
      h_name = Printf.sprintf "race:%d" n;
      h_redundancy = max 1 n;
      h_dispatch = (fun scheduler run jobs -> run_concurrent scheduler run n jobs) }
  | Remote member -> { serial_handler with
      h_name = Printf.sprintf "remote:%s" member;
      h_dispatch = (fun _ _ jobs -> remote_dispatch ~member jobs) }

let create ~handler = {
  handler;
  live_children = Hashtbl.create 16;
  signal_handler = None;
  fork_count = 0;
  fork_log_path = Sys.getenv_opt "PP_FORK_LOG";
}

let current_handler t = t.handler
let install t handler = t.handler <- handler
let schedules_batches t = t.handler != serial_handler
let redundancy t = t.handler.h_redundancy

let dispatch_batch (scheduler : t) ~(run : runner) (jobs : job list) : unit =
  scheduler.handler.h_dispatch scheduler run jobs
