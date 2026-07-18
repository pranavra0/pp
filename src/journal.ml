(* pp journal — the append-only intent/done audit log (LAW 31).

   One typed entry variant owns every line shape; [to_line]/[of_line] live
   together so a writer cannot invent a dialect the scanner does not read.
   Line formats are FROZEN — tests and tooling grep this log.

   Convergent domains (fs, proc) journal intent/done as an audit trail only:
   recovery is re-running reconcile, not replay (desired state is cheap to
   recompute, observed state is re-derived from cells). Fenced effects use
   the same journal as a WAL: an `intent fenced` with no later matching
   `done fenced` is an unknown-status action that must be resolved by
   --fenced-policy before normal reconciliation proceeds. *)

type entry =
  | Exec of string list
      (* every external process execution — "null rebuild executes zero
         processes" is proved by these lines, not merely asserted *)
  | DomainIntent of { hash : string; fields : (string * string) list }
      (* Generic per-pass bracket, shared by every registered write-domain
         (fs, proc, and third-party). [fields] is an ORDERED k=v list the
         domain's own diff assembled (its :summary) — core does not know or
         care what the keys mean, only how to print/journal them, which is
         what makes this format-compatible with the OLD fs-only
         `intent HASH root=R create=C update=U delete=D` line: fs's diff
         supplies fields = [("root",R); ("create",C); ("update",U);
         ("delete",D)] in that order, and joining them here reproduces the
         identical bytes (the hash VALUE differs — it is now the generic
         plan-cache key, H(diff-code, observed, desired), not the old
         bespoke desired-only hash; no test or tool depends on the digits,
         only the shape, which is preserved exactly). *)
  | DomainDone of { hash : string }
  | ProcStartIntent of { name : string; spec_hash : string }
  | ProcStartDone of { name : string; spec_hash : string; pid : int }
  | ProcStopIntent of { name : string }
  | ProcStopDone of { name : string }
  | FencedIntent of { key : string; epoch : string; kind : string; spec_hash : string }
  | FencedDone of { key : string; result_hash : string }
  | IslandFetch of { uri : string; pin : string }
      (* every island fetch/re-pin — procurement is auditable *)
  | Epoch of { hash : string }
      (* Recorded once
         per SUCCESSFUL Domains.run_pass pass — [hash] is the desired-state
         root object's content hash (Identity.hash_value of the fully-forced
         `all_desired` value that pass converged). This is the audit-log
         half of GC's root bookkeeping (frozen line shape, greppable, never
         rotated); the REPLAYABLE half (which files/grants/flags reproduce
         that hash) is deliberately NOT here — journal lines are frozen text
         grepped by tests/tooling, not a place to grow a rich, evolving
         schema — it lives in src/gcroots.ml's own small manifest instead. *)

let to_line = function
  | Exec argv -> "exec " ^ String.concat " " argv
  | DomainIntent { hash; fields } ->
      "intent " ^ hash
      ^ String.concat "" (List.map (fun (k, v) -> " " ^ k ^ "=" ^ v) fields)
  | DomainDone { hash } -> "done " ^ hash
  | ProcStartIntent { name; spec_hash } ->
      Printf.sprintf "intent proc start %s %s" name spec_hash
  | ProcStartDone { name; spec_hash; pid } ->
      Printf.sprintf "done proc start %s %s pid=%d" name spec_hash pid
  | ProcStopIntent { name } -> Printf.sprintf "intent proc stop %s" name
  | ProcStopDone { name } -> Printf.sprintf "done proc stop %s" name
  | FencedIntent { key; epoch; kind; spec_hash } ->
      Printf.sprintf "intent fenced %s %s %s %s" key epoch kind spec_hash
  | FencedDone { key; result_hash } ->
      Printf.sprintf "done fenced %s %s" key result_hash
  | IslandFetch { uri; pin } ->
      Printf.sprintf "island fetch %s %s" uri pin
  | Epoch { hash } -> "epoch " ^ hash

(* Best-effort inverse. Only the fenced dialect is ever read back for
   recovery decisions; other shapes parse when unambiguous and fall to None
   otherwise. Lines are unquoted, space-separated text by design — greppable,
   not a rich schema — so an element containing a space (a service name, or an
   `Exec` argv element like a path with a space) round-trips lossily here.
   That is deliberate and safe: writers embed such elements verbatim for the
   audit log, and nothing downstream re-reads proc or exec lines. *)
let of_line (line : string) : entry option =
  match String.split_on_char ' ' (String.trim line) with
  | "exec" :: argv -> Some (Exec argv)
  | ["epoch"; hash] -> Some (Epoch { hash })
  | ["island"; "fetch"; uri; pin] -> Some (IslandFetch { uri; pin })
  | "intent" :: "fenced" :: key :: epoch :: kind :: spec_hash :: _ ->
      Some (FencedIntent { key; epoch; kind; spec_hash })
  | "done" :: "fenced" :: key :: result_hash :: _ ->
      Some (FencedDone { key; result_hash })
  | "done" :: "fenced" :: key :: _ ->
      Some (FencedDone { key; result_hash = "" })
  | "intent" :: "proc" :: "start" :: [name; spec_hash] ->
      Some (ProcStartIntent { name; spec_hash })
  | "done" :: "proc" :: "start" :: [name; spec_hash; pidkv] ->
      (match String.split_on_char '=' pidkv with
       | ["pid"; p] ->
           (match int_of_string_opt p with
            | Some pid -> Some (ProcStartDone { name; spec_hash; pid })
            | None -> None)
       | _ -> None)
  | "intent" :: "proc" :: "stop" :: [name] -> Some (ProcStopIntent { name })
  | "done" :: "proc" :: "stop" :: [name] -> Some (ProcStopDone { name })
  | ["done"; hash] -> Some (DomainDone { hash })
  | "intent" :: hash :: rest when rest <> [] ->
      (let kv s = match String.index_opt s '=' with
         | Some i -> Some (String.sub s 0 i,
                           String.sub s (i + 1) (String.length s - i - 1))
         | None -> None
       in
       Some (DomainIntent { hash; fields = List.filter_map kv rest }))
  | _ -> None

(* ---- The log file ---- *)

let journal_dir = Filename.concat (Store_layout.root Store_layout.default) "journal"
let log_path () = Filename.concat journal_dir "log"

(* Concurrent-writer safety: one line is one Unix.write_substring on an O_APPEND fd.
   A buffered out_channel's [output_string]+[close_out] is two syscalls (a
   write from the buffer, then the close's flush of whatever didn't fit) and
   nothing stops the OCaml runtime from splitting a long line across more
   than one underlying write() — under N concurrent writers, POSIX only
   guarantees O_APPEND write() atomicity for a SINGLE write() call, so a
   split write can interleave with another process's line and corrupt both.
   One write_substring per line, on an fd opened O_APPEND every call (so the
   "seek to end + write" is one atomic kernel operation), keeps every journal
   line whole regardless of length or how many processes are appending. *)
let append (e : entry) : unit =
  Store_layout.ensure_dir journal_dir;
  let line = to_line e ^ "\n" in
  let fd = Unix.openfile (log_path ())
             [Unix.O_WRONLY; Unix.O_APPEND; Unix.O_CREAT] 0o644 in
  Fun.protect ~finally:(fun () -> try Unix.close fd with _ -> ()) (fun () ->
    ignore (Unix.write_substring fd line 0 (String.length line)))

(* Fold every parseable entry in journal order. *)
let fold (f : 'a -> entry -> 'a) (init : 'a) : 'a =
  let path = log_path () in
  if not (Sys.file_exists path) then init
  else begin
    let ic = open_in path in
    let acc = ref init in
    (try
       while true do
         match of_line (input_line ic) with
         | Some e -> acc := f !acc e
         | None -> ()
       done
     with End_of_file -> ());
    close_in ic;
    !acc
  end

(* ---- Fenced-effect scanners (LAW 31) ---- *)

type fenced_entry = {
  fe_key : string;
  fe_epoch : string;
  fe_kind : string;
  fe_spec_hash : string;
}

(* Fenced intents without a matching done, in journal order (oldest first).
   Only the most recent unmatched intent for a given key is meaningful, but
   all are returned so recovery can process them in order. *)
let pending_fenced_actions () : fenced_entry list =
  let pending : (string, string * string * string) Hashtbl.t = Hashtbl.create 16 in
  fold (fun () e ->
    match e with
    | FencedIntent { key; epoch; kind; spec_hash } ->
        Hashtbl.replace pending key (epoch, kind, spec_hash)
    | FencedDone { key; _ } -> Hashtbl.remove pending key
    | _ -> ()) ();
  Hashtbl.fold (fun key (epoch, kind, spec_hash) acc ->
    { fe_key = key; fe_epoch = epoch; fe_kind = kind; fe_spec_hash = spec_hash } :: acc)
    pending []

(* Whether a fenced key already has a done entry — used at action time to
   avoid re-executing an action completed in a prior pass. *)
let has_fenced_done (key : string) : bool =
  let (pending, seen) =
    fold (fun (pending, seen) e ->
      match e with
      | FencedIntent { key = k; _ } when k = key -> (true, true)
      | FencedDone { key = k; _ } when k = key -> (false, true)
      | _ -> (pending, seen)) (false, false)
  in
  seen && not pending
