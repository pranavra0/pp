(* pp persistent store — ~/.pp/store/ with BLAKE2B objects + trace sets

   Layout:
     ~/.pp/store/
       objects/<result-hash>   — immutable value blobs (OCaml Marshal),
                                 content-addressed by the hash of the value
       blobs/<sha256>          — raw file bytes, content-addressed by the same
                                 hash a file cell observes (Q11 ingest; also
                                 the reconciler's blob-ref source)
       traces/<node-key>       — a SET of verifying traces (OCaml Marshal),
                                 each recording outcome, result-hash, and the
                                 (cell-id, observed-hash) world-reads the node
                                 made. A cached result is *valid* iff some
                                 stored trace still verifies against the world
                                 (SPEC LAW 21) — identity (the node key) and
                                 validity (the trace) are deliberately separate.
       journal/                — reconciler + exec journal (Q4)

   Concurrency: temp file + atomic rename; immutable objects ⇒ benign races.
   Serialization: OCaml Marshal (same-version, same-architecture — local cache).
*)

open Types

(* ---- Store paths ---- *)

let store_root =
  let home = Sys.getenv "HOME" in
  Filename.concat home ".pp/store"

let objects_dir = Filename.concat store_root "objects"
let traces_dir = Filename.concat store_root "traces"

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

let store_object ~key ~value =
  ensure_dirs ();
  let path = obj_path key in
  if not (Sys.file_exists path) then (
    let bytes = Marshal.to_bytes value [Marshal.Closures] in
    let content = Bytes.to_string bytes in
    atomic_write path content
  )

let load_object ~key =
  let path = obj_path key in
  if Sys.file_exists path then (
    try
      let ic = open_in_bin path in
      let len = in_channel_length ic in
      let content = really_input_string ic len in
      close_in ic;
      let value = Marshal.from_bytes (Bytes.of_string content) 0 in
      Some value
    with _ -> None  (* corrupted or version-mismatched → treat as miss *)
  ) else
    None

(* ---- Trace storage ----
   A trace records what a node run OBSERVED, so a later run can decide whether
   the stored result is still valid without re-running. One node key maps to a
   SET of traces (R9): the same code can have been validly built under different
   observed worlds (toolchains, platforms, file contents), and a hit succeeds if
   *any* stored trace still verifies. Serialized with Marshal so cell-ids and
   hashes need no delimiter escaping. *)

type trace_outcome = Ok | Failed

type trace = {
  tr_outcome : trace_outcome;
  tr_result_hash : string;
  tr_reads : (string * string) list;  (* (cell-id, observed-hash) *)
}

let load_traces ~key : trace list =
  let path = trace_path key in
  if Sys.file_exists path then (
    try
      let ic = open_in_bin path in
      let len = in_channel_length ic in
      let content = really_input_string ic len in
      close_in ic;
      (Marshal.from_bytes (Bytes.of_string content) 0 : trace list)
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
    let bytes = Marshal.to_bytes set [] in
    atomic_write (trace_path key) (Bytes.to_string bytes)
  )

(* ---- Cell observation and trace verification ----
   A cell-id is "file:<canonical-path>". Its observed hash is the hash of the
   file's current contents; a missing/unreadable cell observes as None, which
   never matches a recorded hash (so it forces a miss). *)

(* A file cell-id is "file:<path>" using the path exactly as the program passed
   it — the same string the perform-time capability check and `observe_cell` use,
   so the hit-time authority check (LAW 23b) and the staleness check agree.
   Uniform realpath canonicalization (of grants, cells, and perform-time checks
   together) is future work; canonicalizing only the cell would desync it from
   the raw-path grant check (e.g. /var vs /private/var on macOS). *)
let file_cell_id (path : string) : string =
  "file:" ^ path

(* A stat cell — "stat:<path>" — records what a file *predicate* observed:
   presence and kind, never contents. Precise for file-exists?/dir?: creating
   or deleting the path invalidates, content edits do not; a trace that
   observed absence re-verifies while the path stays absent. *)
let stat_cell_id (path : string) : string =
  "stat:" ^ path

let stat_kind (path : string) : string =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } -> "dir"
  | exception _ -> "absent"
  | _ -> "file"

let stat_kind_hash (kind : string) : string =
  hash_string ("stat:" ^ kind)

(* Environment observations: "env:<NAME>" — value or absence. *)
let env_cell_id (name : string) : string = "env:" ^ name
let env_observed_hash (v : string option) : string =
  match v with
  | Some s -> hash_string ("env:" ^ s)
  | None -> hash_string "env:absent"

(* The single argv cell: the program-argument list after `--`. *)
let argv_cell_id : string = "argv:"
let argv_observed_hash () : string =
  hash_concat ("argv" :: !Runtime.program_argv)

let strip_prefix (prefix : string) (s : string) : string option =
  let plen = String.length prefix in
  if String.length s >= plen && String.sub s 0 plen = prefix then
    Some (String.sub s plen (String.length s - plen))
  else None

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

let observe_cell (cell_id : string) : string option =
  match strip_prefix "file:" cell_id with
  | Some path ->
      (* Q11: a pinned cell re-observes its run snapshot, keeping validity
         decisions consistent with what this run's nodes actually read. *)
      (match Hashtbl.find_opt run_pins cell_id with
       | Some h -> Some h
       | None -> hash_file_opt path)
  | None ->
  match strip_prefix "runtime:file:" cell_id with
  | Some path ->
      (* A loader read (Q6): re-observed like a file cell; authority-exempt
         at hit time (the read was the interpreter's, not the user's). *)
      hash_file_opt path
  | None ->
  match strip_prefix "tool:" cell_id with
  | Some path ->
      (* The command binary a `run` resolved to (D13): re-observed as its
         current content hash, like a file cell under a different authority
         rule (process grant, not fs — see cell_authorized). *)
      hash_file_opt path
  | None ->
  match strip_prefix "tree:" cell_id with
  | Some root -> (try Some (tree_hash root) with _ -> None)
  | None ->
  match strip_prefix "stat:" cell_id with
  | Some path -> Some (stat_kind_hash (stat_kind path))
  | None ->
  match strip_prefix "env:" cell_id with
  | Some name -> Some (env_observed_hash (Sys.getenv_opt name))
  | None ->
  if cell_id = argv_cell_id then Some (argv_observed_hash ())
  else
      (* Config and handler cells re-observe the CALLER's ambient stacks
         (LAW 33/26) through the same helpers that recorded them. *)
      match strip_prefix "config:" cell_id with
      | Some key -> (try Some (Runtime.observe_config key) with _ -> None)
      | None ->
          match strip_prefix "handler:" cell_id with
          | Some name -> (try Some (Runtime.observe_handler name) with _ -> None)
          | None -> None  (* unknown cell kind: cannot re-observe ⇒ never verifies *)

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

(* ---- Reconciler journal (Q4) ----
   An append-only audit log: `intent <hash> ...` before an apply, `done <hash>`
   after it. Recovery is not replay — desired state is cheap to recompute and
   observed state is re-derived from cells, so crash recovery = re-running
   reconcile; the journal exists to make what happened inspectable. *)

let journal_dir = Filename.concat store_root "journal"

let journal_append (line : string) : unit =
  ensure_dir journal_dir;
  let oc = open_out_gen [Open_append; Open_creat] 0o644
      (Filename.concat journal_dir "log") in
  output_string oc (line ^ "\n");
  close_out oc


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
  
(* ---- Init called at startup ---- *)

let init () =
  ensure_dirs ()
