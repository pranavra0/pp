(* pp persistent store — ~/.pp/store/ with BLAKE2B objects + trace sets

   Layout:
     ~/.pp/store/
       objects/<hash>          — immutable value blobs (OCaml Marshal)
       traces/<hash>           — trace sets: one line per trace
                                  "ok <result-hash>"
                                  "failed <error-hash>"
       journal/                — reconciler journal (Q4, future)

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
   Format: one trace per line, each line is:
     ok:<result-hash>
     failed:<error-hash>
   Loading returns a list of (outcome, result_hash) pairs. *)

type trace_outcome = Ok | Failed

let store_trace ~key ~outcome ~result_hash =
  ensure_dirs ();
  let path = trace_path key in
  let line =
    (match outcome with Ok -> "ok:" | Failed -> "failed:")
    ^ result_hash ^ "\n" in
  if Sys.file_exists path then (
    (* Read existing traces to check for duplicates *)
    let existing =
      try
        let ic = open_in path in
        let len = in_channel_length ic in
        let content = if len > 0 then really_input_string ic len else "" in
        close_in ic;
        content
      with _ -> "" in
    if not (List.mem line (String.split_on_char '\n' existing)) then
      atomic_write path (existing ^ line)
  ) else
    atomic_write path line

let load_traces ~key =
  let path = trace_path key in
  if Sys.file_exists path then (
    try
      let ic = open_in path in
      let len = in_channel_length ic in
      let content = really_input_string ic len in
      close_in ic;
      let lines = String.split_on_char '\n' content in
      List.filter_map (fun line ->
        if String.length line < 3 then None
        else if String.sub line 0 3 = "ok:" then
          Some (Ok, String.sub line 3 (String.length line - 3))
        else if String.sub line 0 7 = "failed:" then
          Some (Failed, String.sub line 7 (String.length line - 7))
        else None
      ) lines
    with _ -> []
  ) else
    []

(* ---- Init called at startup ---- *)

let init () =
  ensure_dirs ()
