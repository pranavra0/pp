(* pp gc — explicit store GC (M5 stage C: docs/PLAN-m5-distribution.md
   "Store GC"). NEVER automatic — the only entry point is the `pp gc` CLI
   command (main.ml).

   Roots = the last N recorded epochs (Gcroots.read_all — already capped to
   N at write time, domains.ml's record_epoch) + their transitive blob:
   refs. Mark-by-replay (the contract's load-bearing finding: traces do not
   record child-keys, so there is no on-disk node graph to walk): for each
   recorded root, re-run the IDENTICAL `pp` invocation (same files/grants/
   flags — Gcroots' whole reason for existing) as a `--gc-mark` subprocess,
   which runs the program (deriving its desired-state value exactly as a
   live pass would) but SKIPS domain apply/fenced-drain entirely (main.ml's
   --gc-mark branch) — every `Store.hit` verified along the way marks its
   trace/object/blob(s) live (store.ml's [gc_marking]/[mark_live]), so the
   replay only ever touches the store's read path, never performs a real
   write, subprocess exec, or fenced action UNLESS the world has genuinely
   drifted since that epoch (a documented residual: a drifted root replays
   like any ordinary rebuild would — real but idempotent recomputation, not
   a hidden unsoundness; over-marking from a recompute is always safe).

   Safety under concurrency (a build racing this sweep — the tests/038/050
   shape): (1) a creation-time grace period — nothing younger than
   [grace_seconds] is ever a deletion candidate, so a build that just wrote
   a fresh object/trace/blob during the sweep is untouched regardless of
   whether the mark pass saw it; (2) a delete-time re-check of the roots
   manifest immediately before committing to delete anything — if the
   manifest's own bytes changed since the mark pass read it (a NEW
   reconcile pass completed concurrently, appending an epoch this sweep
   never replayed), the sweep stops deleting for the rest of THIS
   invocation rather than risk sweeping something the new epoch needs.
   Over-retention is always safe; deleting live data is the only hazard —
   every choice here is biased toward "keep it" whenever in doubt: if even
   ONE recorded root fails to replay cleanly, the WHOLE sweep is refused
   (never a partial, best-guess deletion). Only objects/, traces/, blobs/
   are ever swept — fenced-specs/, procs/, journal/, and the islands cache
   (~/.pp/islands, a separate lifecycle entirely) are never touched. *)

let default_grace_seconds = 2.0

(* ---- Replay: spawn `pp <reconstructed argv> --gc-mark <outfile>` ---- *)

let argv_of_root (r : Gcroots.root) (mark_out : string) : string list =
  (if r.Gcroots.gr_bytecode then ["--bytecode"] else [])
  @ List.concat_map (fun g -> ["--grant"; g]) r.Gcroots.gr_grants
  @ (match r.Gcroots.gr_reconcile_root with
     | Some root -> ["--reconcile"; root] | None -> [])
  @ (if r.Gcroots.gr_supervise then ["--supervise"] else [])
  @ (match r.Gcroots.gr_member_name with
     | Some n -> ["--member-name"; n] | None -> [])
  @ (match r.Gcroots.gr_desired_object with
     | Some (h, root) -> ["--desired-object"; h; root] | None -> [])
  @ ["--schedule"; "serial"; "--gc-mark"; mark_out]
  @ r.Gcroots.gr_files

(* Runs the replay subprocess to completion; on a clean (exit 0) run with a
   readable mark file, returns the marked ids; on ANY failure (nonzero
   exit, crash, missing/unreadable output) returns [None] and leaves a
   diagnostic in [log_path] — [run] (below) treats any [None] as "refuse
   the whole sweep", never a partial mark. *)
let run_replay (exe : string) (r : Gcroots.root) : string list option =
  let mark_out = Filename.temp_file "pp-gc-mark" "" in
  (try Sys.remove mark_out with _ -> ());
  let log_path = mark_out ^ ".log" in
  let argv = argv_of_root r mark_out in
  let fd_out =
    Unix.openfile log_path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600 in
  let fd_in = Unix.openfile "/dev/null" [Unix.O_RDONLY] 0 in
  let pid =
    Fun.protect ~finally:(fun () -> Unix.close fd_in; Unix.close fd_out)
      (fun () -> Unix.create_process exe (Array.of_list (exe :: argv)) fd_in fd_out fd_out)
  in
  let (_, status) = Unix.waitpid [] pid in
  let ok = match status with Unix.WEXITED 0 -> true | _ -> false in
  if ok && Sys.file_exists mark_out then begin
    let lines =
      String.split_on_char '\n' (Store.read_raw mark_out)
      |> List.filter (fun l -> l <> "")
    in
    (try Sys.remove mark_out with _ -> ());
    (try Sys.remove log_path with _ -> ());
    Some lines
  end else begin
    Printf.eprintf
      "pp gc: replay of root %s failed (see %s for the subprocess's own output)\n%!"
      r.Gcroots.gr_hash log_path;
    None
  end

(* ---- The sweep ---- *)

let manifest_snapshot () : string option =
  let path = Gcroots.roots_path () in
  if Sys.file_exists path then Some (Store.read_raw path) else None

let sweep_dir (dir : string) (prefix : string) (live : (string, unit) Hashtbl.t)
    (grace_seconds : float) (snapshot : string option) (aborted : bool ref)
    : int * int =
  if not (Sys.file_exists dir) then (0, 0)
  else
    let names = Array.to_list (Sys.readdir dir) in
    let now = Unix.gettimeofday () in
    List.fold_left (fun (kept, deleted) name ->
      let path = Filename.concat dir name in
      if Hashtbl.mem live (prefix ^ name) then (kept + 1, deleted)
      else begin
        let young =
          match Unix.stat path with
          | st -> now -. st.Unix.st_mtime < grace_seconds
          | exception _ -> true  (* vanished mid-scan — treat as "don't touch" *)
        in
        if young then (kept + 1, deleted)
        else if !aborted then (kept + 1, deleted)
        else if manifest_snapshot () <> snapshot then begin
          aborted := true;
          Printf.eprintf
            "pp gc: roots manifest changed mid-sweep (a concurrent reconcile \
             pass completed) — stopping further deletes this run for safety; \
             re-run `pp gc` to continue\n%!";
          (kept + 1, deleted)
        end else begin
          (try Sys.remove path with _ -> ());
          (kept, deleted + 1)
        end
      end)
      (0, 0) names

let run ~(grace_seconds : float) : unit =
  let roots = Gcroots.read_all () in
  if roots = [] then
    Printf.printf
      "pp gc: no recorded roots (~/.pp/store/gc-roots is empty) — nothing \
       to do; run a --reconcile/--supervise/register-domain pass first\n"
  else begin
    let exe = Sys.executable_name in
    let live : (string, unit) Hashtbl.t = Hashtbl.create 256 in
    let all_ok = ref true in
    List.iter (fun r ->
      match run_replay exe r with
      | Some marks -> List.iter (fun m -> Hashtbl.replace live m ()) marks
      | None -> all_ok := false)
      roots;
    if not !all_ok then begin
      Printf.eprintf
        "pp gc: one or more recorded roots failed to replay — refusing to \
         sweep (over-retention is always safe; a partial/best-guess sweep \
         is not)\n%!";
      exit 1
    end;
    let snapshot = manifest_snapshot () in
    let aborted = ref false in
    let (ko, do_) = sweep_dir Store.objects_dir "object:" live grace_seconds snapshot aborted in
    let (kt, dt) = sweep_dir Store.traces_dir "trace:" live grace_seconds snapshot aborted in
    let (kb, db) = sweep_dir Store.blobs_dir "blob:" live grace_seconds snapshot aborted in
    Printf.printf
      "pp gc: objects kept=%d deleted=%d, traces kept=%d deleted=%d, blobs kept=%d deleted=%d\n"
      ko do_ kt dt kb db
  end
