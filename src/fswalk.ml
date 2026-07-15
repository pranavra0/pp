(* Filesystem tree walk — one shared implementation for the five callers
   that each independently traversed the filesystem (delete, copy, hash,
   collect).  Pre-order: for a directory the callback is called with an
   [Entry] before child entries are visited.  The [visit] type reports
   stat/readdir failures so callers that need error markers (tree_hash)
   can add them, while callers that prefer silent skipping (remove_tree,
   tree_observe) can ignore the error variants. *)

type visit =
  | Entry of Unix.stats
  | Lstat_failed
  | Readdir_failed

let rec walk ~root ~(cb : rel:string -> path:string -> visit -> unit) : unit =
  match Unix.lstat root with
  | exception _ -> cb ~rel:"" ~path:root Lstat_failed
  | { Unix.st_kind = Unix.S_DIR; _ } as st ->
      cb ~rel:"" ~path:root (Entry st);
      walk_dir root "" cb
  | st ->
      cb ~rel:"" ~path:root (Entry st)

and walk_dir dir rel cb =
  match Sys.readdir dir with
  | exception _ -> cb ~rel ~path:dir Readdir_failed
  | names ->
      Array.iter (fun name ->
        let p = Filename.concat dir name in
        let r = if rel = "" then name else rel ^ "/" ^ name in
        match Unix.lstat p with
        | exception _ -> cb ~rel:r ~path:p Lstat_failed
        | { Unix.st_kind = Unix.S_DIR; _ } as st ->
            cb ~rel:r ~path:p (Entry st);
            walk_dir p r cb
        | st ->
            cb ~rel:r ~path:p (Entry st)
      ) names
