(* pp persistent store — ~/.pp/store/ with SHA-256-addressed objects + trace sets

   Layout:
     ~/.pp/store/
       VERSION                 — "pp-store 1\n"; stamps the format below (M2.2)
       objects/<result-hash>   — immutable value blobs, canonical s-expr TEXT
                                 (Codec.encode_value), content-addressed by
                                 the hash of the value. DATA only — see LAW
                                 below.
       blobs/<sha256>          — raw file bytes, content-addressed by the same
                                 hash a file cell observes (Q11 ingest; also
                                 the reconciler's blob-ref source). Format-
                                 independent: survives a VERSION wipe.
       traces/<node-key>       — a SET of verifying traces, canonical s-expr
                                 TEXT (one trace per line), each recording
                                 outcome, result-hash, and the (cell-id,
                                 observed-hash) world-reads the node made. A
                                 cached result is *valid* iff some stored
                                 trace still verifies against the world (SPEC
                                 LAW 21) — identity (the node key) and
                                 validity (the trace) are deliberately separate.
       fenced-specs/<hash>     — canonical s-expr TEXT (Codec.encode_value);
                                 DATA only, enforced at registration (fenced.ml).
       procs/<svc-hash>        — supervisor proc state, canonical s-expr TEXT.
       journal/                — reconciler + exec journal (Q4): append-only
                                 line text, untouched by this module, survives
                                 a VERSION wipe (it's an audit log, not a cache).

   Concurrency: temp file + atomic rename; immutable objects ⇒ benign races.

   Serialization: a canonical, versioned TEXT codec (Codec, src/codec.ml) —
   byte-stable across OS/arch/compiler, replacing OCaml Marshal (ROADMAP §3,
   M2.2). THE NON-DATA LAW: the persistent store holds DATA; code values
   (closures, thunks, environments) are process-local. [Codec.encode_value]
   returns [None] for anything containing code, and [store_object] silently
   declines to write in that case — the in-memory memoization already served
   the value within this process, and a cross-process consumer that needs it
   finds the trace verified but the object absent, which is the EXISTING
   "object gone → recompute" path below (unrelated to this codec — it always
   existed for a merely-evicted object). A store-format version mismatch (or
   a missing VERSION on a non-empty store) wipes objects/, traces/, fenced-
   specs/, and procs/ — see [init] — but never blobs/ or journal/. *)

open Types

(* ---- Store paths ---- *)

let store_root =
  let home = Sys.getenv "HOME" in
  Filename.concat home ".pp/store"

let objects_dir = Filename.concat store_root "objects"
let traces_dir = Filename.concat store_root "traces"
let version_path = Filename.concat store_root "VERSION"
(* BUMP THIS whenever anything about the on-disk format changes — the codec
   grammar (codec.ml), the trace line shape, Types.canonical_float_string, or
   which dirs are versioned. tests/037's golden fixtures are the tripwire: a
   format change without a bump (and a regenerated store-vN fixture set)
   fails byte-comparison there. *)
let current_version_line = "pp-store 1\n"

let rec ensure_dir dir =
  if not (Sys.file_exists dir) then (
    (try ensure_dir (Filename.dirname dir) with _ -> ());
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  )

let ensure_dirs () =
  ensure_dir objects_dir;
  ensure_dir traces_dir

let obj_path hash =
  Filename.concat objects_dir hash

let trace_path hash =
  Filename.concat traces_dir hash

(* ---- Atomic file write ---- *)

let atomic_write path content =
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  (try output_string oc content
   with exn -> close_out oc; Sys.remove tmp; raise exn);
  close_out oc;
  Unix.rename tmp path

(* ---- Object storage ---- *)

(* THE NON-DATA LAW (see header): a value containing code/env/handles encodes
   to [None] and is simply never written. The in-memory memo already served
   it in this process; a later process's trace-verified hit finds no object
   here and recomputes via [hit]'s existing "object gone → recompute" arm. *)
let store_object ~key ~value =
  ensure_dirs ();
  let path = obj_path key in
  if not (Sys.file_exists path) then (
    match Codec.encode_value value with
    | Some content -> atomic_write path content
    | None -> ()
  )

let load_object ~key =
  let path = obj_path key in
  if Sys.file_exists path then (
    try
      let ic = open_in_bin path in
      let len = in_channel_length ic in
      let content = really_input_string ic len in
      close_in ic;
      Codec.decode_value content
    with _ -> None  (* corrupted → treat as miss *)
  ) else
    None

(* ---- Trace storage ----
   A trace records what a node run OBSERVED, so a later run can decide whether
   the stored result is still valid without re-running. One node key maps to a
   SET of traces (R9): the same code can have been validly built under different
   observed worlds (toolchains, platforms, file contents), and a hit succeeds if
   *any* stored trace still verifies.

   Serialized as one canonical s-expr line per trace (file = concatenation):
     (trace ok|failed "RESULT-HASH" (("CELL-ID" . "HASH") ...))
   Cell-ids and hashes are arbitrary strings (a cell-id embeds a filesystem
   path, which may contain spaces or parens) so both are quoted with
   [Codec.quote_string] — the same escaping the value codec uses, reused here
   rather than duplicated, even though this line shape (with its "." pairs)
   is bespoke and not itself a Types.value. *)

type trace_outcome = Ok | Failed

type trace = {
  tr_outcome : trace_outcome;
  tr_result_hash : string;
  tr_reads : (string * string) list;  (* (cell-id, observed-hash) *)
}

let trace_to_line (tr : trace) : string =
  let outcome_s = match tr.tr_outcome with Ok -> "ok" | Failed -> "failed" in
  let read_s (c, h) =
    Printf.sprintf "(%s . %s)" (Codec.quote_string c) (Codec.quote_string h)
  in
  Printf.sprintf "(trace %s %s (%s))"
    outcome_s (Codec.quote_string tr.tr_result_hash)
    (String.concat " " (List.map read_s tr.tr_reads))

(* Hand-rolled parser matching [trace_to_line] exactly; [None] on anything
   that doesn't (a corrupted or old-format line → the caller drops it).
   Written with a local Option-bind operator — a plain chain of "parse one
   piece, thread the index forward" steps, rather than accumulating match
   nesting one paren per step. *)
let line_to_trace (line : string) : trace option =
  let len = String.length line in
  let expect_char i c = if i < len && line.[i] = c then Some (i + 1) else None in
  let expect_lit i lit =
    let l = String.length lit in
    if i + l <= len && String.sub line i l = lit then Some (i + l) else None
  in
  let ( >>= ) o f = match o with None -> None | Some x -> f x in
  let parse_outcome i =
    match expect_lit i "ok " with
    | Some j -> Some (Ok, j)
    | None ->
        (match expect_lit i "failed " with
         | Some j -> Some (Failed, j)
         | None -> None)
  in
  (* One "(CELL . HASH)" entry. *)
  let parse_read i =
    expect_char i '(' >>= fun i ->
    Codec.parse_quoted_string line i >>= fun (cell, i) ->
    expect_lit i " . " >>= fun i ->
    Codec.parse_quoted_string line i >>= fun (hash, i) ->
    expect_char i ')' >>= fun i ->
    Some ((cell, hash), i)
  in
  let rec parse_reads i acc =
    if i < len && line.[i] = ')' then Some (List.rev acc, i + 1)
    else
      parse_read i >>= fun (r, i) ->
      let i = match expect_char i ' ' with Some i -> i | None -> i in
      parse_reads i (r :: acc)
  in
  expect_lit 0 "(trace " >>= fun i ->
  parse_outcome i >>= fun (outcome, i) ->
  Codec.parse_quoted_string line i >>= fun (result_hash, i) ->
  expect_char i ' ' >>= fun i ->
  expect_char i '(' >>= fun i ->
  parse_reads i [] >>= fun (reads, i) ->
  expect_char i ')' >>= fun i ->
  if i = len then Some { tr_outcome = outcome; tr_result_hash = result_hash; tr_reads = reads }
  else None

let load_traces ~key : trace list =
  let path = trace_path key in
  if Sys.file_exists path then (
    try
      let ic = open_in path in
      let lines = ref [] in
      (try
         while true do lines := input_line ic :: !lines done
       with End_of_file -> ());
      close_in ic;
      List.filter_map line_to_trace (List.rev !lines)
    with _ -> []  (* corrupted or old-format → treat as no traces *)
  ) else
    []

let store_trace ~key ~outcome ~result_hash ~reads =
  ensure_dirs ();
  let tr = { tr_outcome = outcome; tr_result_hash = result_hash;
             tr_reads = reads } in
  let existing = load_traces ~key in
  if not (List.mem tr existing) then (
    let set = existing @ [tr] in
    let content = String.concat "" (List.map (fun t -> trace_to_line t ^ "\n") set) in
    atomic_write (trace_path key) content
  )

(* ---- Cell observation and trace verification ----
   A cell-id is "file:<canonical-path>". Its observed hash is the hash of the
   file's current contents; a missing/unreadable cell observes as None, which
   never matches a recorded hash (so it forces a miss). *)

(* A file cell-id is "file:<canonical-path>" (SPEC LAW 23 / DESIGN §2.1):
   the path is canonicalized once, here, via Runtime.canonical_path, so the
   hit-time authority check (which canonicalizes independently in
   Capabilities.path_grants) and the staleness check agree regardless of
   which spelling (symlink, /var vs /private/var, trailing slash) the
   program used. *)
let file_cell_id (path : string) : string =
  Cell.(to_string (File (Runtime.canonical_path path)))

(* A stat cell — "stat:<canonical-path>" — records what a file *predicate*
   observed: presence and kind, never contents. Precise for file-exists?/
   dir?: creating or deleting the path invalidates, content edits do not; a
   trace that observed absence re-verifies while the path stays absent. *)
let stat_cell_id (path : string) : string =
  Cell.(to_string (Stat (Runtime.canonical_path path)))

let stat_kind (path : string) : string =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> "dir"
  | exception _ -> "absent"
  | _ -> "file"

let stat_kind_hash (kind : string) : string =
  hash_string ("stat:" ^ kind)

(* Environment observations: "env:<NAME>" — value or absence. *)
let env_cell_id (name : string) : string = Cell.(to_string (Env name))
let env_observed_hash (v : string option) : string =
  match v with
  | Some s -> hash_string ("env:" ^ s)
  | None -> hash_string "env:absent"

(* The single argv cell: the program-argument list after `--`. *)
let argv_cell_id : string = Cell.to_string Cell.Argv
let argv_observed_hash () : string =
  hash_concat ("argv" :: !Runtime.program_argv)

let hash_file_opt (path : string) : string option =
  try
    let ic = open_in_bin path in
    let len = in_channel_length ic in
    let content = really_input_string ic len in
    close_in ic;
    Some (hash_string content)
  with _ -> None

(* Whole-tree content hash — DESIGN Q2's coarse-cell soundness floor for the
   `run` effect: every regular file under [root] contributes its relative path
   and content hash (sorted); symlinks contribute their target, other kinds a
   marker. Coarse — ANY change under the root invalidates — but sound and
   cheaply re-observable; per-tool depfile adapters refine it later. *)
let tree_hash (root : string) : string =
  let entries = ref [] in
  let add rel part = entries := (rel ^ "=" ^ part) :: !entries in
  let rec walk dir rel =
    match Sys.readdir dir with
    | exception _ -> add rel "unreadable-dir"
    | names ->
        Array.sort compare names;
        Array.iter (fun name ->
          let p = Filename.concat dir name in
          let r = if rel = "" then name else rel ^ "/" ^ name in
          match Unix.lstat p with
          | exception _ -> add r "unstattable"
          | st ->
              (match st.Unix.st_kind with
               | Unix.S_DIR -> walk p r
               | Unix.S_REG ->
                   add r (match hash_file_opt p with
                          | Some h -> h | None -> "unreadable")
               | Unix.S_LNK ->
                   add r ("link->" ^ (try Unix.readlink p with _ -> "?"))
               | _ -> add r "special"))
          names
  in
  (match Unix.lstat root with
   | exception _ -> add "" "missing"
   | { Unix.st_kind = Unix.S_DIR; _ } -> walk root ""
   | _ -> add "" (match hash_file_opt root with Some h -> h | None -> "unreadable"));
  hash_concat ("tree" :: List.sort compare !entries)

let blobs_dir = Filename.concat store_root "blobs"

let store_blob (content : string) : string =
  ensure_dir blobs_dir;
  let h = hash_string content in
  let path = Filename.concat blobs_dir h in
  if not (Sys.file_exists path) then atomic_write path content;
  h

let load_blob (h : string) : string option =
  try
    let ic = open_in_bin (Filename.concat blobs_dir h) in
    let len = in_channel_length ic in
    let s = really_input_string ic len in
    close_in ic; Some s
  with _ -> None

(* Per-run pin table: cell-id → content hash of the run's snapshot. *)
let run_pins : (string, string) Hashtbl.t = Hashtbl.create 64

let unpin_file (path : string) : unit =
  Hashtbl.remove run_pins (file_cell_id path)

(* Re-observe a cell's current world state (one arm per Cell kind). *)
let observe_cell (cell_id : string) : string option =
  match Cell.of_string cell_id with
  | Cell.File path ->
      (* Q11: a pinned cell re-observes its run snapshot, keeping validity
         decisions consistent with what this run's nodes actually read. *)
      (match Hashtbl.find_opt run_pins cell_id with
       | Some h -> Some h
       | None -> hash_file_opt path)
  | Cell.RuntimeFile path ->
      (* A loader read (Q6): re-observed like a file cell; authority-exempt
         at hit time (the read was the interpreter's, not the user's). *)
      hash_file_opt path
  | Cell.Tool path ->
      (* The command binary a `run` resolved to (D13): re-observed as its
         current content hash, like a file cell under a different authority
         rule (process grant, not fs — see cell_authorized). *)
      hash_file_opt path
  | Cell.Tree root -> (try Some (tree_hash root) with _ -> None)
  | Cell.Stat path -> Some (stat_kind_hash (stat_kind path))
  | Cell.Env name -> Some (env_observed_hash (Sys.getenv_opt name))
  | Cell.Argv -> Some (argv_observed_hash ())
  (* Config and handler cells re-observe the CALLER's ambient stacks
     (LAW 33/26) through the same helpers that recorded them. *)
  | Cell.Config key -> (try Some (Runtime.observe_config key) with _ -> None)
  | Cell.Handler name -> (try Some (Runtime.observe_handler name) with _ -> None)
  | Cell.Proc name -> (try Runtime.observe_proc name with _ -> None)
  | Cell.Unknown _ -> None  (* cannot re-observe ⇒ never verifies *)

let trace_verifies (tr : trace) : bool =
  List.for_all (fun (cell_id, recorded_hash) ->
    match observe_cell cell_id with
    | Some current -> current = recorded_hash
    | None -> false)
    tr.tr_reads

(* Record a world-read made by the currently-forcing node(s). Called from the
   read primitives (slurp, read-file). *)
let record_file_read (path : string) (content : string) : unit =
  Runtime.record_read (file_cell_id path) (hash_string content)

(* ---- Q11: snapshot-as-CAS-ingest — torn reads are dead ----

   blobs/<sha256> holds raw file bytes, content-addressed by the same hash a
   file cell observes. The first observation of a file cell
   ingests the bytes and pins (cell → hash) for the rest of the run; later
   reads serve the pinned CAS copy, so one run can never observe two
   versions of one cell; a scripting write-file calls [unpin_file] so pp's
   own writes stay coherent with later reads. *)

let read_raw (path : string) : string =
  let ic = open_in path in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic; content

(* Read a file AS A CELL OBSERVATION (slurp / perform read-file). Raises
   Sys_error like a bare read. The first observation ingests the bytes into
   the CAS and pins (cell -> hash); every later read serves the pinned copy —
   one run, one world snapshot, at every tier (the in-memory CA dedup already
   memoizes identical read exprs, so tier-split freshness was never
   coherent). Only pp's own write-file advances a cell's snapshot
   (unpin_file). *)
let read_file_cell (path : string) : string =
  let cell = file_cell_id path in
  let serve content h =
    Runtime.record_read cell h;
    content
  in
  match Hashtbl.find_opt run_pins cell with
  | Some h ->
      (match load_blob h with
       | Some content -> serve content h
       | None ->
           (* Blob evicted mid-run: fall back to disk and re-pin. *)
           let content = read_raw path in
           let h' = store_blob content in
           Hashtbl.replace run_pins cell h';
           serve content h')
  | None ->
      let content = read_raw path in
      let h = hash_string content in
      ignore (store_blob content);
      Hashtbl.replace run_pins cell h;
      serve content h

(* Result of a cache lookup: a verified success, a verified (memoized) failure
   to re-raise (LAW 28), or a miss. *)
type hit_result =
  | HitOk of value
  | HitFailed of value   (* the stored error value, to be re-raised *)
  | Miss

(* ---- Phase-1 tooling switches (set by main.ml from the CLI) ---- *)

let no_cache = ref false      (* --no-cache: skip cache READS; still write *)
let why_mode = ref false      (* pp why / --why: explain hits and misses *)
let check_mode = ref false    (* --check: double-run determinism audit *)
let volatile_count = ref 0    (* nodes flagged volatile by --check *)

let short_key (k : string) : string =
  if String.length k > 12 then String.sub k 0 12 else k

let why fmt =
  if !why_mode then Printf.eprintf ("[why] " ^^ fmt ^^ "\n%!")
  else Printf.ifprintf stderr fmt

(* Attempt a cache hit for [key]. Serves a stored result only if some stored
   trace both (a) still verifies against the current world and (b) is one whose
   entire recorded read closure the caller is [authorized] to read — the LAW 23b
   transitive check that stops a narrow-capability caller from laundering a broad
   read through a cached aggregator (DESIGN Q6). Because reads propagate to
   enclosing nodes, `tr_reads` already IS the transitive closure. A verified
   success is preferred over a verified failure. On a hit the trace's reads are
   replayed into the active trace frames so a parent's trace transitively
   subsumes the reads behind a nested hit. A memoized failure is re-served
   (HitFailed) while its reads still match — it re-runs as soon as one changes
   (LAW 28).

   [authorized] takes a cell-id and returns whether the caller's capabilities
   permit reading it; the check lives in the caller because `Capabilities` is
   compiled after this module.

   `why` reporting is capability-filtered (LAW 23c): a cell the caller has no
   authority over is never named — it appears as a redaction marker — so `why`
   cannot be used to probe what a broader caller's trace read. *)
let hit ~key ~authorized : hit_result =
  if !no_cache then begin
    why "node %s: miss — cache reads disabled (--no-cache)" (short_key key);
    Miss
  end else begin
    let traces = load_traces ~key in
    let describe c = if authorized c then c else "<redacted unauthorized cell>" in
    (* Why a trace is unusable: the first stale cell, else the first
       unauthorized one; `Usable otherwise. *)
    let classify t =
      match
        List.find_opt (fun (c, h) ->
          match observe_cell c with
          | Some cur -> cur <> h
          | None -> true)
          t.tr_reads
      with
      | Some (c, _) -> `Stale c
      | None ->
          (match List.find_opt (fun (c, _) -> not (authorized c)) t.tr_reads with
           | Some (c, _) -> `Unauthorized c
           | None -> `Usable)
    in
    let classified = List.mapi (fun i t -> (i + 1, t, classify t)) traces in
    if !why_mode then
      List.iter (fun (i, _, cls) ->
        match cls with
        | `Stale c ->
            why "node %s: trace %d/%d stale — %s changed"
              (short_key key) i (List.length traces) (describe c)
        | `Unauthorized c ->
            why "node %s: trace %d/%d unauthorized — caller lacks authority over %s"
              (short_key key) i (List.length traces) (describe c)
        | `Usable -> ())
        classified;
    let usable_traces =
      List.filter_map (fun (_, t, cls) -> if cls = `Usable then Some t else None)
        classified
    in
    let chosen =
      match List.find_opt (fun t -> t.tr_outcome = Ok) usable_traces with
      | Some t -> Some t
      | None -> List.find_opt (fun t -> t.tr_outcome = Failed) usable_traces
    in
    match chosen with
    | None ->
        (if traces = [] then
           why "node %s: miss — no stored trace (first build)" (short_key key)
         else
           why "node %s: miss — no stored trace usable" (short_key key));
        Miss
    | Some tr ->
        (match load_object ~key:tr.tr_result_hash with
         | None ->
             why "node %s: miss — result object missing from store" (short_key key);
             Miss  (* object gone → recompute *)
         | Some v ->
             why "node %s: hit — %s trace verified (%d cells)"
               (short_key key)
               (match tr.tr_outcome with Ok -> "ok" | Failed -> "failing")
               (List.length tr.tr_reads);
             List.iter (fun (c, h) -> Runtime.record_read c h) tr.tr_reads;
             (match tr.tr_outcome with Ok -> HitOk v | Failed -> HitFailed v))
  end

(* The intent/done audit log lives in journal.ml (typed entries, one
   to_line/of_line pair). Fenced-spec persistence stays here: it is content-
   addressed object storage, same as the rest of the store. *)

(* Fenced specs are persisted by content hash so recovery can re-execute an
   unknown-status action with the same spec that produced the intent. *)
let fenced_specs_dir = Filename.concat store_root "fenced-specs"

(* A fenced spec that is not DATA is rejected at registration (fenced.ml's
   [register]), never here: by the time a spec reaches this call it is
   already known to encode. *)
let store_fenced_spec ~(hash : string) (value : Types.value) : unit =
  ensure_dir fenced_specs_dir;
  let path = Filename.concat fenced_specs_dir hash in
  if not (Sys.file_exists path) then
    match Codec.encode_value value with
    | Some content -> atomic_write path content
    | None -> ()

let load_fenced_spec (hash : string) : Types.value option =
  let path = Filename.concat fenced_specs_dir hash in
  if Sys.file_exists path then
    try Codec.decode_value (read_raw path) with _ -> None
  else None


(* ---- Phase 2: reverse-edge index for push stabilize ----
   Scans ~/.pp/store/traces/ and builds cell-id → node-key list.
   Includes ALL cell types (no handler:log filter) so dirty
   propagation is complete. *)
let build_reverse_index () : (string, string list) Hashtbl.t =
  let trace_files = if Sys.file_exists traces_dir then
    Array.to_list (Sys.readdir traces_dir) else [] in
  let cell_to_keys = Hashtbl.create 64 in
  List.iter (fun key ->
    let traces = load_traces ~key in
    let cells = List.sort_uniq compare
      (List.concat_map (fun tr ->
        List.map (fun (c, _) -> c) tr.tr_reads) traces) in
    List.iter (fun c ->
      let prev = try Hashtbl.find cell_to_keys c with Not_found -> [] in
      Hashtbl.replace cell_to_keys c (key :: prev)) cells
  ) (List.sort compare trace_files);
  cell_to_keys

(* Given changed cell-ids and a reverse index, compute the dirty node-key
   set (transitive by construction: a parent's trace transitively subsumes
   its children's reads via hit-replay, so the index already captures the
   full dirty cone). *)
let dirty_keys_for (changed_cell_ids : string list)
    (rev : (string, string list) Hashtbl.t) : string list =
  let dirty = Hashtbl.create 64 in
  List.iter (fun cell_id ->
    match Hashtbl.find_opt rev cell_id with
    | Some keys -> List.iter (fun k -> Hashtbl.replace dirty k ()) keys
    | None -> ()) changed_cell_ids;
  Hashtbl.fold (fun k () acc -> k :: acc) dirty []

(* ---- Phase 2: pp graph — print the cell→node dependency graph ----
   Scans ~/.pp/store/traces/ and shows which cells each node reads,
   and which nodes depend on each cell (the reverse-edge index).
   By default filters out handler:log cells (internal noise); pass
   ~verbose:true to show every cell. *)
let print_graph ?(verbose = false) () =
  let cell_to_keys = build_reverse_index () in
  let key_to_cells = Hashtbl.create 64 in
  let noise = function
    | c when verbose -> false
    | c -> c = "handler:log"
  in
  (* Build forward index (key → cells) from the reverse index, filtering noise. *)
  Hashtbl.iter (fun cell keys ->
    if not (noise cell) then
      List.iter (fun key ->
        let prev = try Hashtbl.find key_to_cells key with Not_found -> [] in
        Hashtbl.replace key_to_cells key (cell :: prev)) keys
  ) cell_to_keys;
  if Hashtbl.length key_to_cells = 0 then
    Printf.printf "(no traces in store — run a program first)\n"
  else begin
    Printf.printf "pp graph — dependency graph from ~/.pp/store/traces\n\n";
    Printf.printf "Nodes → Cells (forward edges):\n";
    Hashtbl.iter (fun key cells ->
      let cells_str = if cells = [] then "(none)" else String.concat ", " cells in
      Printf.printf "  node %s\n    reads: %s\n" (short_key key) cells_str
    ) key_to_cells;
    Printf.printf "\nCells → Nodes (reverse edges):\n";
    Hashtbl.iter (fun cell keys ->
      if not (noise cell) then
        Printf.printf "  %s\n    used by: %s\n" cell
          (String.concat ", " (List.map short_key keys))
    ) cell_to_keys;
    Printf.printf "\n%d node(s), %d unique cell(s)\n"
      (Hashtbl.length key_to_cells) (Hashtbl.length cell_to_keys)
  end
  
(* ---- Version stamp (M2.2) ----
   ~/.pp/store/VERSION pins the codec above. [procs_dir] is defined here (not
   in supervisor.ml, which reads it as [Store.procs_dir]) so this module can
   name every format-versioned directory in one place. *)

let procs_dir = Filename.concat store_root "procs"

(* The dirs whose ON-DISK FORMAT is governed by VERSION. blobs/ (raw bytes)
   and journal/ (append-only audit text) are format-independent and are
   never touched by a version wipe. *)
let versioned_dirs = [objects_dir; traces_dir; fenced_specs_dir; procs_dir]

let dir_nonempty dir =
  Sys.file_exists dir && (try Array.length (Sys.readdir dir) > 0 with _ -> false)

let store_has_content () = List.exists dir_nonempty versioned_dirs

let read_version () : string option =
  if Sys.file_exists version_path then
    try
      let ic = open_in_bin version_path in
      let len = in_channel_length ic in
      let s = really_input_string ic len in
      close_in ic; Some s
    with _ -> None
  else None

(* Best-effort: remove every entry under [dir] (not [dir] itself). A
   version bump must never crash regardless of what an old/foreign-format
   store contains, so every step is wrapped and failures are swallowed. *)
let wipe_dir_contents dir =
  if Sys.file_exists dir then
    (try
       Array.iter (fun name ->
         let p = Filename.concat dir name in
         try
           if Sys.is_directory p then begin
             Array.iter (fun n -> try Sys.remove (Filename.concat p n) with _ -> ())
               (Sys.readdir p);
             (try Unix.rmdir p with _ -> ())
           end else Sys.remove p
         with _ -> ())
         (Sys.readdir dir)
     with _ -> ())

(* Wipe order: every versioned dir's CONTENTS first, VERSION written LAST.
   A crash mid-wipe can then never leave stale-format files readable as
   current-version — either VERSION is still old/absent (next run wipes
   again, idempotent) or the wipe fully completed before VERSION flipped. *)
let wipe_versioned_dirs () = List.iter wipe_dir_contents versioned_dirs

(* ---- Init called at startup ---- *)

let init () =
  ensure_dirs ();
  match read_version () with
  | Some v when v = current_version_line -> ()
  | Some _ | None ->
      (* Missing VERSION + empty store: nothing to wipe, just stamp it.
         Missing/mismatched VERSION + non-empty store: wipe the versioned
         dirs (never blobs/ or journal/), then stamp current. Corrupted
         old-store content is never read as current-version — it's gone. *)
      if store_has_content () then begin
        prerr_endline
          ("pp: store format changed — clearing cached objects/traces under "
           ^ store_root ^ " (blobs and journal kept); everything recomputes \
              on first use");
        wipe_versioned_dirs ()
      end;
      atomic_write version_path current_version_line
