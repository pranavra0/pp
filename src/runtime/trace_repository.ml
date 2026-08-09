open Pp_kernel
type outcome = Ok | Failed

type trace = {
  outcome : outcome;
  result_hash : Identity_types.Object_hash.t;
  reads : (Identity_types.Cell_id.t * Identity_types.Observed_hash.t) list;
}
type t = { layout : Store_layout.t }
let create layout = { layout }

let to_line (tr : trace) : string =
  let outcome_s = match tr.outcome with Ok -> "ok" | Failed -> "failed" in
  let read_s (c, h) =
    Printf.sprintf "(%s . %s)"
      (Codec.quote_string (Identity_types.Cell_id.to_string c))
      (Codec.quote_string (Identity_types.Observed_hash.to_string h))
  in
  Printf.sprintf "(trace %s %s (%s))"
    outcome_s
      (Codec.quote_string
         (Identity_types.Object_hash.to_string tr.result_hash))
    (String.concat " " (List.map read_s tr.reads))

(* Hand-rolled parser matching [to_line] exactly; malformed or noncanonical
   records are ignored when loading the append-only trace set. *)
let is_canonical_digest s =
  String.length s = 64
  && String.for_all
       (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) s

let valid_cell_string s =
  String.length s > 0
  && String.for_all (fun c -> Char.code c >= 32 && Char.code c <> 127) s
  &&
  try Cell.serialize (Cell.parse s) = s with _ -> false

let of_line (line : string) : trace option =
  if String.exists (fun c -> c = '\r' || c = '\n') line then None else
  try
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
    let parse_read i =
      expect_char i '(' >>= fun i ->
      Codec.parse_quoted_string line i >>= fun (cell, i) ->
      expect_lit i " . " >>= fun i ->
      Codec.parse_quoted_string line i >>= fun (hash, i) ->
      expect_char i ')' >>= fun i ->
      if valid_cell_string cell && is_canonical_digest hash then
        Some ((Identity_types.Cell_id.of_string cell,
               Identity_types.Observed_hash.of_digest hash), i)
      else None
    in
    let rec parse_reads i acc =
      if i < len && line.[i] = ')' then Some (List.rev acc, i + 1)
      else
        parse_read i >>= fun (r, next) ->
        if next < len && line.[next] = ')' then
          parse_reads next (r :: acc)
        else
          expect_char next ' ' >>= fun after_space ->
          parse_reads after_space (r :: acc)
    in
    expect_lit 0 "(trace " >>= fun i ->
    parse_outcome i >>= fun (outcome, i) ->
    Codec.parse_quoted_string line i >>= fun (result_hash, i) ->
    if not (is_canonical_digest result_hash) then None else
    expect_char i ' ' >>= fun i ->
    expect_char i '(' >>= fun i ->
    parse_reads i [] >>= fun (reads, i) ->
    expect_char i ')' >>= fun i ->
    if i = len then
      let tr = { outcome = outcome;
                 result_hash = Identity_types.Object_hash.of_digest result_hash;
                 reads = reads } in
      if to_line tr = line then Some tr else None
    else None
  with _ -> None
let load t ~(key : Identity_types.Cache_key.t) : trace list =
  let path = Store_layout.path t.layout Store_layout.Traces
    (Identity_types.Cache_key.to_string key) in
  try
    let fd = Store_layout.open_read path in
    let ic = Unix.in_channel_of_descr fd in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let len = in_channel_length ic in
        if len = 0 then []
        else begin
          seek_in ic (len - 1);
          if input_char ic <> '\n' then []
          else begin
            seek_in ic 0;
            let rec read_lines acc =
              try
                let line = input_line ic in
                match of_line line with
                | Some tr -> read_lines (tr :: acc)
                | None -> read_lines acc
              with End_of_file -> List.rev acc
            in
            read_lines []
          end
        end)
  with
  | Exit | Sys_error _ | Unix.Unix_error _ | End_of_file -> []

(* ---- Concurrent-writer safety: per-key lock around the traces/<key> RMW ----

   Two workers computing DIFFERENT nodes never contend (distinct lock
   files); two workers computing the SAME node (a Race, or two independent
   `pp` invocations landing on one node) serialize here instead of racing
   "read existing set, append, atomic-rename" — without the lock, the
   loser's rename can clobber the winner's freshly-written set, dropping a
   trace. That drop is already sound without a lock: the
   survivor either duplicates the loser's trace — determinism — or the
   loser's world simply re-misses and recomputes; never a wrong hit) — the
   lock only turns "sound but occasionally wasteful" into "sound and the
   waste doesn't happen in practice." [PP_TRACE_LOCK=0] disables the lock
   (checked once, lazily) so a stress test can demonstrate the
   drop-soundness fallback still holds with it off — an internal escape
   hatch, not user-facing. *)
let trace_lock_enabled =
  lazy (match Sys.getenv_opt "PP_TRACE_LOCK" with Some "0" -> false | _ -> true)



let with_trace_lock t (key : Identity_types.Cache_key.t) (f : unit -> unit) : unit =
  if not (Lazy.force trace_lock_enabled) then f ()
  else begin
    Store_layout.ensure_area t.layout Store_layout.Locks;
    let lock_path = Store_layout.path t.layout Store_layout.Locks
      (Identity_types.Cache_key.to_string key) in
    match (try Some (Store_layout.open_rw lock_path)
           with Unix.Unix_error _ -> None) with
    | None -> f ()  (* lock acquisition is best-effort; correctness is atomic replace *)
    | Some fd ->
        Unix.fchmod fd 0o600;
        Fun.protect
          ~finally:(fun () ->
            try Unix.close fd with Unix.Unix_error _ -> ())
          (fun () ->
            (try Unix.lockf fd Unix.F_LOCK 0 with Unix.Unix_error _ -> ());
            Fun.protect
              ~finally:(fun () ->
                try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ())
              f)
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
      Store_layout.atomic_replace
        (Store_layout.path t.layout Store_layout.Traces
           (Identity_types.Cache_key.to_string key)) content
    ))
let keys t = Store_layout.list t.layout Store_layout.Traces
  |> List.filter is_canonical_digest
  |> List.map Identity_types.Cache_key.of_string
