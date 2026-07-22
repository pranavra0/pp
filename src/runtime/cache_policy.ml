open Pp_kernel
open Core_model

type result = HitOk of value | HitFailed of value | Miss
type trace_status = Usable | Stale of Identity_types.Cell_id.t |
  Unauthorized of Identity_types.Cell_id.t
type miss_reason = Cache_reads_disabled | No_stored_trace |
  No_usable_trace | Result_object_missing
type decision =
  | Cache_hit of {
      outcome : Trace_repository.outcome;
      result_hash : Identity_types.Object_hash.t;
      cell_count : int;
    }
  | Cache_miss of miss_reason
type lookup_report = {
  key : Identity_types.Cache_key.t;
  traces : (int * int * trace_status) list;
  decision : decision;
}
type t = {
  mutable no_cache : bool;
  mutable why_enabled : bool;
  mutable check_enabled : bool;
  mutable volatile_count : int;
  mutable gc_live : (string, unit) Hashtbl.t option;
}
let create () = { no_cache = false; why_enabled = false; check_enabled = false;
  volatile_count = 0; gc_live = None }
let default = create ()
let configure t ~no_cache ~why ~check =
  t.no_cache <- no_cache; t.why_enabled <- why; t.check_enabled <- check
let enable_no_cache t = t.no_cache <- true
let enable_why t = t.why_enabled <- true
let set_why t value = t.why_enabled <- value
let why_enabled t = t.why_enabled
let enable_check t = t.check_enabled <- true
let check_enabled t = t.check_enabled
let volatile_count t = t.volatile_count
let reset_volatile t = t.volatile_count <- 0
let note_volatile t = t.volatile_count <- t.volatile_count + 1
let begin_gc t = t.gc_live <- Some (Hashtbl.create 1024)
let end_gc t = let live = t.gc_live in t.gc_live <- None; live
let gc_marks t = Option.value ~default:(Hashtbl.create 0) t.gc_live
let mark t id = Option.iter (fun live -> Hashtbl.replace live id ()) t.gc_live
let short_key key = if String.length key > 12 then String.sub key 0 12 else key
let diagnose t fmt =
  if t.why_enabled then Printf.eprintf ("[why] " ^^ fmt ^^ "\n%!")
  else Printf.ifprintf stderr fmt

let format_report ~authorized report =
  let key = short_key (Identity_types.Cache_key.to_string report.key) in
  let describe cell =
    if authorized cell then Identity_types.Cell_id.to_string cell
    else "<redacted unauthorized cell>"
  in
  let trace_lines = List.filter_map (fun (index, count, status) ->
    match status with
    | Stale cell -> Some (Printf.sprintf
        "node %s: trace %d/%d stale — %s changed"
        key index count (describe cell))
    | Unauthorized cell -> Some (Printf.sprintf
        "node %s: trace %d/%d unauthorized — caller lacks authority over %s"
        key index count (describe cell))
    | Usable -> None) report.traces
  in
  let decision_line = match report.decision with
    | Cache_miss Cache_reads_disabled ->
        Printf.sprintf "node %s: miss — cache reads disabled (--no-cache)" key
    | Cache_miss No_stored_trace ->
        Printf.sprintf "node %s: miss — no stored trace (first build)" key
    | Cache_miss No_usable_trace ->
        Printf.sprintf "node %s: miss — no stored trace usable" key
    | Cache_miss Result_object_missing ->
        Printf.sprintf "node %s: miss — result object missing from store" key
    | Cache_hit { outcome; cell_count; _ } ->
        Printf.sprintf "node %s: hit — %s trace verified (%d cells)" key
          (match outcome with Trace_repository.Ok -> "ok" | Trace_repository.Failed -> "failing")
          cell_count
  in
  trace_lines @ [decision_line]

let lookup_with_report t ~(key : Identity_types.Cache_key.t)
    ~(authorized : Identity_types.Cell_id.t -> bool) : result * lookup_report =
  if t.no_cache then begin
    let report = { key; traces = []; decision = Cache_miss Cache_reads_disabled } in
    (Miss, report)
  end else begin
    let traces = Trace_repository.load Trace_repository.default ~key in
    (* Report only the first stale or unauthorized cell so diagnostics do not
       disclose or traverse more trace data than the cache decision needs. *)
    let classify trace =
      match
        List.find_opt (fun (c, h) ->
          match Observation.observe_id c with
          | Some cur -> cur <> h
          | None -> true)
          trace.Trace_repository.reads
      with
      | Some (c, _) -> Stale c
      | None ->
           (match List.find_opt (fun (c, _) -> not (authorized c)) trace.Trace_repository.reads with
           | Some (c, _) -> Unauthorized c
           | None -> Usable)
    in
    let classified = List.mapi (fun i t -> (i + 1, t, classify t)) traces in
    let usable_traces =
      List.filter_map (fun (_, trace, status) ->
        if status = Usable then Some trace else None)
        classified
    in
    let chosen =
      match List.find_opt (fun t -> t.Trace_repository.outcome = Trace_repository.Ok) usable_traces with
      | Some t -> Some t
      | None -> List.find_opt (fun t -> t.Trace_repository.outcome = Trace_repository.Failed) usable_traces
    in
    match chosen with
    | None ->
        let reason = if traces = [] then No_stored_trace else No_usable_trace in
        (Miss, { key;
          traces = List.map (fun (i, _, status) -> (i, List.length traces, status)) classified;
          decision = Cache_miss reason })
    | Some tr ->
        (match Object_repository.get Object_repository.default
                 ~key:(Identity_types.Object_hash.to_string
                         tr.Trace_repository.result_hash) with
         | None ->
             (Miss, { key;
               traces = List.map (fun (i, _, status) -> (i, List.length traces, status)) classified;
               decision = Cache_miss Result_object_missing })
         | Some v ->
             Observation.replay tr.Trace_repository.reads;
             (* GC mark (see [gc_marking]'s header comment above):
                a verified hit means this trace/object/blob(s) are LIVE for
                whichever root program is currently being replayed. *)
             mark t ("trace:" ^ Identity_types.Cache_key.to_string key);
             mark t ("object:" ^
               Identity_types.Object_hash.to_string tr.Trace_repository.result_hash);
             List.iter (fun (c, h) ->
               match Cell.parse (Identity_types.Cell_id.to_string c) with
               | Cell.File _ ->
                   mark t ("blob:" ^ Identity_types.Observed_hash.to_string h)
               | _ -> ())
               tr.Trace_repository.reads;
             List.iter (fun h -> mark t ("blob:" ^ h)) (Blobref.blob_refs_in v);
             let result = match tr.Trace_repository.outcome with
               | Trace_repository.Ok -> HitOk v
               | Trace_repository.Failed -> HitFailed v
             in
             (result, { key;
               traces = List.map (fun (i, _, status) -> (i, List.length traces, status)) classified;
               decision = Cache_hit {
                 outcome = tr.Trace_repository.outcome;
                 result_hash = tr.Trace_repository.result_hash;
                 cell_count = List.length tr.Trace_repository.reads;
               } }))
  end

let lookup t ~key ~authorized =
  let result, report = lookup_with_report t ~key ~authorized in
  if t.why_enabled then
    List.iter (fun line -> diagnose t "%s" line) (format_report ~authorized report);
  result
