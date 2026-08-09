open Pp_kernel
open Core_model

type result = HitOk of value | HitFailed of value | Miss
type t = {
  mutable no_cache : bool;
  mutable why_enabled : bool;
  mutable check_enabled : bool;
  mutable volatile_count : int;
}
let create () = { no_cache = false; why_enabled = false; check_enabled = false;
  volatile_count = 0 }
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
let short_key key = if String.length key > 12 then String.sub key 0 12 else key
let event kind key reason =
  let value = VMap [
    VKeyword "kind", VKeyword kind;
    VKeyword "node", VString (short_key key);
    VKeyword "reason", VKeyword reason
  ] in
  try ignore (Effect.perform (Effects.Record_event value)) with _ -> ()
let diagnose t fmt =
  if t.why_enabled then Printf.eprintf ("[why] " ^^ fmt ^^ "\n%!")
  else Printf.ifprintf stderr fmt
let lookup t ~(traces : Trace_repository.t) ~(objects : Object_repository.t)
    ~(blobs : Blob_repository.t)
    ~(observe_id : Identity_types.Cell_id.t ->
      Identity_types.Observed_hash.t option)
    ~(replay : (Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list -> unit)
    ~(key : Identity_types.Cache_key.t)
    ~(authorized : Identity_types.Cell_id.t -> bool) : result =
  if t.no_cache then begin
    event "node-cache" (Identity_types.Cache_key.to_string key) "disabled";
    diagnose t "node %s: miss — cache reads disabled (--no-cache)"
      (short_key (Identity_types.Cache_key.to_string key));
    Miss
  end else begin
    let traces = Trace_repository.load traces ~key in
    let describe c =
      if authorized c then Identity_types.Cell_id.to_string c
      else "<redacted unauthorized cell>"
    in
    (* Authorization precedes reobservation: whether an unauthorized cell
       changed is itself information the caller may not learn. *)
    let classify t =
      match List.find_opt (fun (c, _) -> not (authorized c))
              t.Trace_repository.reads
      with
      | Some (c, _) -> `Unauthorized c
      | None ->
          (match
             List.find_opt (fun (c, h) ->
               match observe_id c with
               | Some cur -> cur <> h
               | None -> true)
               t.Trace_repository.reads
           with
           | Some (c, _) -> `Stale c
           | None -> `Usable)
    in
    let classified = List.mapi (fun i t -> (i + 1, t, classify t)) traces in
    if t.why_enabled then
      List.iter (fun (i, _, cls) ->
        match cls with
        | `Stale c ->
            diagnose t "node %s: trace %d/%d stale — %s changed"
              (short_key (Identity_types.Cache_key.to_string key)) i
              (List.length traces) (describe c)
        | `Unauthorized c ->
            diagnose t "node %s: trace %d/%d unauthorized — caller lacks authority over %s"
              (short_key (Identity_types.Cache_key.to_string key)) i
              (List.length traces) (describe c)
        | `Usable -> ())
        classified;
    let load_result tr =
      match Object_repository.get objects
              ~key:(Identity_types.Object_hash.to_string
                      tr.Trace_repository.result_hash) with
      | None ->
          diagnose t "node %s: trace result object missing or corrupt"
            (short_key (Identity_types.Cache_key.to_string key));
          None
      | Some value ->
          (match List.find_opt (fun hash ->
                   Option.is_none (Blob_repository.get blobs hash))
                   (Artifact_tree.reachable_blobs value) with
           | Some hash ->
               diagnose t "node %s: trace tree blob %s missing or corrupt"
                 (short_key (Identity_types.Cache_key.to_string key))
                 (short_key hash);
               None
           | None -> Some (tr, value))
    in
    let candidates =
      List.filter_map (fun (_, trace, classification) ->
        if classification = `Usable then load_result trace else None)
        classified
    in
    let chosen =
      match List.find_opt (fun (trace, _) ->
              trace.Trace_repository.outcome = Trace_repository.Ok) candidates with
      | Some result -> Some result
      | None ->
          List.find_opt (fun (trace, _) ->
            trace.Trace_repository.outcome = Trace_repository.Failed) candidates
    in
    match chosen with
    | None ->
        event "node-cache" (Identity_types.Cache_key.to_string key) "miss";
        (if traces = [] then
           diagnose t "node %s: miss — no stored trace (first build)"
             (short_key (Identity_types.Cache_key.to_string key))
         else
           diagnose t "node %s: miss — no stored trace usable"
             (short_key (Identity_types.Cache_key.to_string key)));
        Miss
    | Some (trace, value) ->
        event "node-cache" (Identity_types.Cache_key.to_string key) "hit";
        diagnose t "node %s: hit — %s trace verified (%d cells)"
          (short_key (Identity_types.Cache_key.to_string key))
          (match trace.Trace_repository.outcome with
           | Trace_repository.Ok -> "ok"
           | Trace_repository.Failed -> "failing")
          (List.length trace.Trace_repository.reads);
        replay trace.Trace_repository.reads;
        (match trace.Trace_repository.outcome with
         | Trace_repository.Ok -> HitOk value
         | Trace_repository.Failed -> HitFailed value)
  end
