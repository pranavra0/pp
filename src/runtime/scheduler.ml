open Pp_kernel
(* pp scheduler — fork-at-dispatch process-pool scheduler for persistent
   node misses.

   Worker model: fork() at the dispatch
   point inherits ALL ambient state (handler_stack closures, capabilities,
   config, thunk memo) byte-identically via COW — no scope-state refactor and
   no marshaling is needed. A forked worker runs the EXACT function
   the serial miss arm calls, [Node.rebuild] (passed in as
   [j_run] by the caller) — there is no second "evaluate node in worker"
   code path. The child exits 0 on success / 1 on error; the failing trace
   was already persisted by [Node.rebuild] itself. The parent never
   reads a value from a child — it reaps and falls through to the ordinary
   [Cache_policy.lookup Cache_policy.default]: the child's trace+object make it a hit, a dead child makes
   it a miss and the parent recomputes in-process. Worker death therefore
   degrades to "computed serially," never a wrong answer, never a hang.

   No value, closure, capability, or handler ever crosses a process
   boundary this way: the store (~/.pp/store) is pp's only cross-process
   value channel, exactly as it already is for separate `pp` invocations. *)

(* [Remote member]: remote placement — the same handler, over the cluster
   transport, to a named cluster member (ambient config,
   ~/.pp/cluster/members — never --grant, an address is not an authority
   ceiling). *)
type policy = Serial | Parallel of int | Race of int | Remote of string

type job = {
  j_key : Identity_types.Node_key.t;
  j_run : unit -> Core_model.value;
  (* Redundancy for this job: 1 for an ordinary batch member, N for a
     singleton force_node miss raced under [Race n] (N identical (key,run)
     forks — sound because nodes are deterministic; the first
     exit-0 wins). *)
  j_width : int;
  (* The thunk this job forces. Every existing call site already has it in
     scope; the narrow remote dispatcher uses it to test data-closedness. *)
  j_thunk : Core_model.thunk;
}
type t = {
  mutable policy : policy;
  remote_dispatch : member:string -> job list -> unit;
  live_children : (int, Identity_types.Node_key.t) Hashtbl.t;
  mutable signal_handler : Sys.signal_behavior option;
  mutable fork_count : int;
  fork_log_path : string option;
}

let create ~policy ~remote_dispatch = {
  policy;
  remote_dispatch;
  live_children = Hashtbl.create 16;
  signal_handler = None;
  fork_count = 0;
  fork_log_path = Sys.getenv_opt "PP_FORK_LOG";
}

let policy t = t.policy
let set_policy t policy = t.policy <- policy

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

(* Runs entirely inside the child. [j.j_run] IS [Node.rebuild]
   partially applied by the caller — the exact function the serial miss arm
   calls; [Node.rebuild] itself persists the result object and trace on success
   or the failing trace before returning or raising, so there is
   nothing left for the child to persist here. The child must flush its OWN
   stdout/stderr (anything the node body printed via `perform log` or
   otherwise) before terminating: we deliberately call [Unix._exit], which
   — unlike [exit] — skips OCaml's [at_exit] hooks (including the stdlib's
   own channel-flush hook), so a child that didn't flush explicitly would
   silently drop its buffered output. *)
let run_child (j : job) : unit =
  let status = try ignore (j.j_run ()); 0 with _ -> 1 in
  (try flush stdout with _ -> ());
  (try flush stderr with _ -> ());
  Unix._exit status

(* Deterministic, load-independent observability of actual fan-out: what
   matters is "nodes fork to workers," a fork COUNT, not a wall-clock
   time (wall-clock masked a regression once: a shadowed `map` silently
   defeated batching and a timing-only test read it as "no spare cores").
   PP_FORK_LOG=<path> appends one line per fork; a test asserts the count. *)
let fork_job (scheduler : t) (j : job) : int =
  flush_before_fork ();
  match Unix.fork () with
  | 0 -> run_child j; Unix._exit 1 (* unreachable: run_child always _exit's *)
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

(* ---- dispatch_batch ---- *)

(* [Serial]: in-process, in order — byte-identical to calling every job's
   [j_run] directly (callers of dispatch_batch already special-case
   Serial to skip collection/forking entirely, but
   dispatch_batch itself also degrades safely if ever called under Serial). *)
let run_serial (jobs : job list) : unit =
  List.iter (fun j -> ignore (j.j_run ())) jobs

(* [Parallel n] / [Race n]: a wave loop. Each job is expanded into
   [j_width] fork slots (>1 only for a singleton race — all such forks
   share [j_key]). Concurrency is capped at [n]; a completed slot frees room
   for the next queued fork. The FIRST successful (exit 0) child for a given
   key marks that key won: any other STILL-LIVE child sharing the key is a
   race loser and is killed (SIGTERM->SIGKILL) — safe by construction, since
   `(fenced ...)` cannot appear inside a node body, so no
   non-convergent action can ever be half-done inside a killed node. Once a
   key has won, remaining QUEUED (not yet forked) duplicates of that key are
   skipped rather than forked at all. *)
let run_concurrent (scheduler : t) (limit : int) (jobs : job list) : unit =
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
        ignore (fork_job scheduler j);
        incr live_count
      end
    done;
    if !live_count > 0 then reap_one ()
  done

let dispatch_batch (scheduler : t) (jobs : job list) : unit =
  match scheduler.policy with
  | Serial -> run_serial jobs
  | Parallel n | Race n -> run_concurrent scheduler n jobs
  | Remote member -> scheduler.remote_dispatch ~member jobs
