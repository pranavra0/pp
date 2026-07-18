type outcome = Ok | Failed

type trace = {
  outcome : outcome;
  result_hash : string;
  reads : (string * string) list;  (* (cell-id, observed-hash) *)
}
type t = { layout : Store_layout.t }
let create layout = { layout }
let default = create Store_layout.default

let to_line (tr : trace) : string =
  let outcome_s = match tr.outcome with Ok -> "ok" | Failed -> "failed" in
  let read_s (c, h) =
    Printf.sprintf "(%s . %s)" (Codec.quote_string c) (Codec.quote_string h)
  in
  Printf.sprintf "(trace %s %s (%s))"
    outcome_s (Codec.quote_string tr.result_hash)
    (String.concat " " (List.map read_s tr.reads))

(* Hand-rolled parser matching [to_line] exactly; [None] on anything
   that doesn't (a corrupted or old-format line → the caller drops it).
   Thin adapters that delegate to Codec's expect_char/expect_lit/bind — the line
   and len are baked in so callers don't pass them every time. *)
let of_line (line : string) : trace option =
  let len = String.length line in
  let expect_char i c = Codec.expect_char line i c in
  let expect_lit i lit = Codec.expect_lit line i lit in
  let (>>=) = Codec.bind in
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
  if i = len then Some { outcome = outcome; result_hash = result_hash; reads = reads }
  else None

let load t ~key : trace list =
  let path = Store_layout.path t.layout Store_layout.Traces key in
  if Sys.file_exists path then (
    try
      let ic = open_in path in
      let lines = ref [] in
      (try
         while true do lines := input_line ic :: !lines done
       with End_of_file -> ());
      close_in ic;
      List.filter_map of_line (List.rev !lines)
    with _ -> []  (* corrupted or old-format → treat as no traces *)
  ) else
    []

(* ---- Concurrent-writer safety: per-key lock around the traces/<key> RMW ----

   Two workers computing DIFFERENT nodes never contend (distinct lock
   files); two workers computing the SAME node (a Race, or two independent
   `pp` invocations landing on one node) serialize here instead of racing
   "read existing set, append, atomic-rename" — without the lock, the
   loser's rename can clobber the winner's freshly-written set, dropping a
   trace. That drop is already SOUND without any lock at all (LAW 37: the
   survivor either duplicates the loser's trace — determinism — or the
   loser's world simply re-misses and recomputes; never a wrong hit) — the
   lock only turns "sound but occasionally wasteful" into "sound and the
   waste doesn't happen in practice." [PP_TRACE_LOCK=0] disables the lock
   (checked once, lazily) so a stress test can demonstrate the
   drop-soundness fallback still holds with it off — an internal escape
   hatch, not user-facing. *)
let trace_lock_enabled =
  lazy (match Sys.getenv_opt "PP_TRACE_LOCK" with Some "0" -> false | _ -> true)



let with_trace_lock t (key : string) (f : unit -> unit) : unit =
  if not (Lazy.force trace_lock_enabled) then f ()
  else begin
    Store_layout.ensure_area t.layout Store_layout.Locks;
    let lock_path = Store_layout.path t.layout Store_layout.Locks key in
    match (try Some (Unix.openfile lock_path [Unix.O_CREAT; Unix.O_WRONLY] 0o644)
           with _ -> None) with
    | None -> f ()  (* can't lock (e.g. read-only FS) — best-effort, proceed unlocked *)
    | Some fd ->
        Fun.protect ~finally:(fun () -> (try Unix.close fd with _ -> ())) (fun () ->
          (try Unix.lockf fd Unix.F_LOCK 0 with _ -> ());
          Fun.protect ~finally:(fun () -> (try Unix.lockf fd Unix.F_ULOCK 0 with _ -> ())) f)
  end

let put t ~key ~outcome ~result_hash ~reads =
  Store_layout.ensure_area t.layout Store_layout.Traces;
  with_trace_lock t key (fun () ->
    let tr = { outcome = outcome; result_hash = result_hash;
               reads = reads } in
    let existing = load t ~key in
    if not (List.mem tr existing) then (
      let set = existing @ [tr] in
      let content = String.concat "" (List.map (fun t -> to_line t ^ "\n") set) in
      Store_layout.atomic_replace (Store_layout.path t.layout Store_layout.Traces key) content
    ))
let keys t = Store_layout.list t.layout Store_layout.Traces
