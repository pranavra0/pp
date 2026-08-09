(* Append-only intent/done audit log.

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
         schema — it lives in src/runtime/gcroots.ml's own small manifest instead. *)

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

(* Parse the frozen, printable line dialect. Anything outside the exact
   canonical shape is a hard recovery error. *)
let is_digest (s : string) : bool =
  String.length s = 64
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) s

let is_token (s : string) : bool =
  String.length s > 0
  && String.for_all (fun c -> c >= '!' && c <= '~') s

let is_pid (s : string) : bool =
  String.length s > 0
  && (String.length s = 1 || s.[0] <> '0')
  && String.for_all (fun c -> c >= '0' && c <= '9') s
  && (match int_of_string_opt s with
      | Some n -> n >= 0 && string_of_int n = s
      | None -> false)

let of_line (line : string) : entry option =
  if line = "" || String.exists (fun c -> c = '\r' || c = '\n') line then None
  else
    match String.split_on_char ' ' line with
    | "exec" :: argv when argv <> [] && List.for_all is_token argv -> Some (Exec argv)
    | ["epoch"; hash] when is_digest hash -> Some (Epoch { hash })
    | ["island"; "fetch"; uri; pin] when is_token uri && is_token pin ->
        Some (IslandFetch { uri; pin })
    | ["intent"; "fenced"; key; epoch; kind; spec_hash]
      when is_digest key && is_digest epoch && is_token kind && is_digest spec_hash ->
        Some (FencedIntent { key; epoch; kind; spec_hash })
    | ["done"; "fenced"; key; result_hash]
      when is_digest key && is_digest result_hash ->
        Some (FencedDone { key; result_hash })
    | "intent" :: "proc" :: "start" :: [name; spec_hash]
      when is_token name && is_digest spec_hash ->
        Some (ProcStartIntent { name; spec_hash })
    | "done" :: "proc" :: "start" :: [name; spec_hash; pidkv]
      when is_token name && is_digest spec_hash ->
        (match String.split_on_char '=' pidkv with
         | ["pid"; p] when is_pid p ->
             Some (ProcStartDone { name; spec_hash; pid = int_of_string p })
         | _ -> None)
    | "intent" :: "proc" :: "stop" :: [name] when is_token name ->
        Some (ProcStopIntent { name })
    | "done" :: "proc" :: "stop" :: [name] when is_token name ->
        Some (ProcStopDone { name })
    | ["done"; hash] when is_digest hash -> Some (DomainDone { hash })
    | "intent" :: hash :: rest when is_digest hash && rest <> [] ->
        let kv s =
          match String.index_opt s '=' with
          | Some i when i > 0 && i < String.length s - 1 ->
              let k = String.sub s 0 i
              and v = String.sub s (i + 1) (String.length s - i - 1) in
              if is_token k && is_token v
                 && not (String.contains k '=')
                 && not (String.contains v '=') then Some (k, v) else None
          | _ -> None
        in
        let fields = List.filter_map kv rest in
        let names = List.map fst fields in
        if List.length fields = List.length rest
           && List.length (List.sort_uniq String.compare names) = List.length names then
          Some (DomainIntent { hash; fields })
        else None
    | _ -> None

(* ---- The log file ---- *)
let journal_dir () =
  Filename.concat (Store_layout.root (Runtime_context.layout ())) "journal"
let log_path () = Filename.concat (journal_dir ()) "log"

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
  Store_layout.ensure_dir (journal_dir ());
  let raw = to_line e in
  if String.exists (fun c -> c = '\r' || c = '\n') raw then
    invalid_arg "journal: CR/LF in entry";
  if of_line raw = None then
    invalid_arg "journal: entry is not representable";
  let line = raw ^ "\n" in
  let fd = Store_layout.open_append (log_path ()) in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ());
      try Unix.close fd with Unix.Unix_error _ -> ())
    (fun () ->
      Unix.fchmod fd 0o600;
      Unix.lockf fd Unix.F_LOCK 0;
      let rec write_all offset =
        if offset < String.length line then
          let written =
            Unix.write_substring fd line offset (String.length line - offset)
          in
          if written = 0 then failwith "journal: zero-byte append"
          else write_all (offset + written)
      in
      write_all 0;
      Unix.fsync fd)

(* Fold every parseable entry in journal order. *)
let fold (f : 'a -> entry -> 'a) (init : 'a) : 'a =
  let read () =
    let fd = Store_layout.open_read (log_path ()) in
    let ic = Unix.in_channel_of_descr fd in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        if len > 0 then begin
          seek_in ic (len - 1);
          if input_char ic <> '\n' then
            failwith "journal: unterminated final line";
          seek_in ic 0
        end;
        let acc = ref init in
        let line_no = ref 0 in
        (try
           while true do
             incr line_no;
             let line = input_line ic in
             match of_line line with
             | Some e -> acc := f !acc e
             | None ->
                 failwith (Printf.sprintf "journal: malformed line %d" !line_no)
           done
         with End_of_file -> ());
        !acc)
  in
  try read () with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> init

(* ---- Fenced-effect scanners ---- *)

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
  let intents : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  fold (fun () e ->
    match e with
    | FencedIntent { key; epoch; kind; spec_hash } ->
        Hashtbl.replace intents key ();
        Hashtbl.replace pending key (epoch, kind, spec_hash)
    | FencedDone { key; _ } ->
        if not (Hashtbl.mem intents key) then
          failwith "journal: malformed fenced done without a matching intent";
        Hashtbl.remove pending key
    | _ -> ()) ();
  Hashtbl.fold (fun key (epoch, kind, spec_hash) acc ->
    { fe_key = key; fe_epoch = epoch; fe_kind = kind; fe_spec_hash = spec_hash } :: acc)
    pending []

let has_fenced_done (key : string) : bool =
  let (intended, completed) =
    fold (fun (intended, completed) e ->
      match e with
      | FencedIntent { key = k; _ } when k = key -> (true, false)
      | FencedDone { key = k; _ } when k = key && intended -> (intended, true)
      | _ -> (intended, completed)) (false, false)
  in
  intended && completed
