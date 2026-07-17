(* pp scheduler — fork-at-dispatch process-pool scheduler for persistent
   node misses.

   Worker model: fork() at the dispatch
   point inherits ALL ambient state (handler_stack closures, capabilities,
   config, thunk_store) byte-identically via COW — no Runtime.t refactor and
   no marshaling is needed. A forked worker runs the EXACT function
   the serial miss arm calls, [Evaluator.run_node_body] (passed in as
   [j_run] by the caller) — there is no second "evaluate node in worker"
   code path. The child exits 0 on success / 1 on error; the failing trace
   was already persisted by run_node_body itself (LAW 28). The parent NEVER
   reads a value from a child — it reaps and falls through to the ordinary
   [Store.hit]: the child's trace+object make it a hit, a dead child makes
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

(* Ambient; set once from --schedule. Read only in the miss arms and here —
   NEVER by node_key_of, and it never enters a trace (LAW 26
   by construction: this is a result-transparent handler). *)
let policy : policy ref = ref Serial

type job = {
  j_key : string;
  j_run : unit -> Types.value;
  (* Redundancy for this job: 1 for an ordinary batch member, N for a
     singleton force_node miss raced under [Race n] (N identical (key,run)
     forks — sound because LAW 37 nodes are deterministic; the first
     exit-0 wins). *)
  j_width : int;
  (* The thunk this job forces. Every existing call site
     already has it in scope; carried here so remote dispatch can test
     data-closedness (Evaluator.is_data_closed) and read node_caps without
     Scheduler itself depending on Evaluator (see remote_dispatch_hook
     below — the same cycle-breaking indirection Primitives' *_ref values
     already use, because Evaluator depends on Scheduler and Transport
     depends on Evaluator, so a remote dispatcher living above both cannot
     be called directly from here). *)
  j_thunk : Types.thunk;
}

(* ---- Live-child bookkeeping (for SIGINT and race-loser kills) ---- *)

(* pid -> job key, for every child currently forked and not yet reaped. *)
let live_children : (int, string) Hashtbl.t = Hashtbl.create 16

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
   (Runtime.current_sandbox) and is normally removed by the child itself
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
        Runtime.remove_tree (Filename.concat tmp name))
      (Sys.readdir tmp)
  with _ -> ()

let reap_and_cleanup (pid : int) : unit =
  Hashtbl.remove live_children pid;
  cleanup_child_sandboxes pid

(* SIGINT: kill every live child (TERM->KILL) before the process exits, so a
   Ctrl-C never leaves orphaned workers running. Installed once, lazily, the
   first time dispatch_batch actually forks anything. *)
let sigint_installed = ref false

let kill_all_live () =
  let pids = Hashtbl.fold (fun pid _ acc -> pid :: acc) live_children [] in
  List.iter (fun pid -> terminate_pid pid; reap_and_cleanup pid) pids

let install_sigint_handler () =
  if not !sigint_installed then begin
    sigint_installed := true;
    ignore (Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
      kill_all_live ();
      exit 130)))
  end

(* ---- fork/exec-free "exec" of one job in a child ---- *)

(* Unflushed stdio buffers are duplicated across fork() (each process then
   flushes its own copy, printing the parent's pending output twice) — flush
   both channels in the PARENT immediately before every fork. *)
let flush_before_fork () =
  (try flush stdout with _ -> ());
  (try flush stderr with _ -> ())

(* Runs entirely inside the child. [j.j_run] IS [Evaluator.run_node_body]
   partially applied by the caller — the exact function the serial miss arm
   calls; run_node_body itself persists the result object + trace (success)
   or the failing trace (LAW 28) before returning/raising, so there is
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
let fork_count = ref 0
let fork_log_path = lazy (Sys.getenv_opt "PP_FORK_LOG")

let fork_job (j : job) : int =
  flush_before_fork ();
  match Unix.fork () with
  | 0 -> run_child j; Unix._exit 1 (* unreachable: run_child always _exit's *)
  | pid ->
      incr fork_count;
      (match Lazy.force fork_log_path with
       | Some p ->
           (try
              let fd = Unix.openfile p [Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT] 0o644 in
              ignore (Unix.write_substring fd "fork\n" 0 5); Unix.close fd
            with _ -> ())
       | None -> ());
      Hashtbl.replace live_children pid j.j_key; pid

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
   `(fenced ...)` cannot appear inside a node body (LAW 31), so no
   non-convergent action can ever be half-done inside a killed node. Once a
   key has won, remaining QUEUED (not yet forked) duplicates of that key are
   skipped rather than forked at all. *)
let run_concurrent (limit : int) (jobs : job list) : unit =
  install_sigint_handler ();
  let limit = max 1 limit in
  let queue = Queue.create () in
  List.iter (fun j -> for _ = 1 to max 1 j.j_width do Queue.push j queue done) jobs;
  let succeeded_keys : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let live_count = ref 0 in
  let kill_losers_for (key : string) : unit =
    let losers =
      Hashtbl.fold (fun p k acc -> if k = key then p :: acc else acc)
        live_children []
    in
    List.iter (fun p ->
      terminate_pid p;
      reap_and_cleanup p;
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
        if not (Hashtbl.mem live_children pid) then reap_one ()
        else begin
          let key = Hashtbl.find live_children pid in
          reap_and_cleanup pid;
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
        ignore (fork_job j);
        incr live_count
      end
    done;
    if !live_count > 0 then reap_one ()
  done

(* Set by src/remote.ml at startup (main.ml calls Remote.init ()) — Remote
   sits ABOVE Evaluator/Transport/Token in the dependency graph, so its
   dispatch function cannot be called directly from this (much lower)
   module; this ref is the seam, exactly like Primitives.run_node_body_ref
   etc. break the analogous cycle for Evaluator. A batch job this hook
   leaves untouched (non-data-closed, unreachable member, a dead worker,
   ...) is NOT re-run here — it simply stays Unevaluated, and the ORIGINAL
   caller (force_deep_plain's recursive walk, or force_node's Miss arm)
   forces it in-process exactly as it would for a dead local worker: never
   a wrong answer, never a hang, no special-cased "retry locally" code
   needed at this layer. The default no-op is therefore already the safe
   degrade-to-local behavior, not just a placeholder. *)
let remote_dispatch_hook : (member:string -> job list -> unit) ref =
  ref (fun ~member:_ (_ : job list) -> ())

let dispatch_batch (jobs : job list) : unit =
  match !policy with
  | Serial -> run_serial jobs
  | Parallel n | Race n -> run_concurrent n jobs
  | Remote member -> !remote_dispatch_hook ~member jobs
