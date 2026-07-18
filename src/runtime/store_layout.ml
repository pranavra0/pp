type t = { root : string }
type area = Objects | Traces | Blobs | Fenced_specs | Procs | Locks

let default = { root = Filename.concat (Sys.getenv "HOME") ".pp/store" }
let root t = t.root
let area_name = function
  | Objects -> "objects" | Traces -> "traces" | Blobs -> "blobs"
  | Fenced_specs -> "fenced-specs" | Procs -> "procs" | Locks -> "locks"
let area t kind = Filename.concat t.root (area_name kind)
let path t kind name = Filename.concat (area t kind) name

let rec ensure_dir dir =
  if not (Sys.file_exists dir) then begin
    (try ensure_dir (Filename.dirname dir) with _ -> ());
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end
let ensure_area t kind = ensure_dir (area t kind)
let list t kind =
  let dir = area t kind in
  if Sys.file_exists dir then Array.to_list (Sys.readdir dir) else []
let read path =
  try
    let ic = open_in_bin path in
    let value = really_input_string ic (in_channel_length ic) in
    close_in ic; Some value
  with _ -> None

let crash_spec = lazy (match Sys.getenv_opt "PP_CRASH_AT" with
  | Some value ->
      (match String.split_on_char ':' value with
       | [boundary; count] -> Option.map (fun n -> boundary, n) (int_of_string_opt count)
       | _ -> None)
  | None -> None)
let write_count = ref 0
let maybe_crash boundary = match Lazy.force crash_spec with
  | Some (expected, count) when expected = boundary && !write_count = count ->
      Unix.kill (Unix.getpid ()) Sys.sigkill
  | _ -> ()
let atomic_replace path content =
  incr write_count; maybe_crash "before";
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  (try output_string oc content with exn -> close_out oc; Sys.remove tmp; raise exn);
  maybe_crash "mid"; close_out oc; maybe_crash "pre-rename";
  Unix.rename tmp path; maybe_crash "post-rename"

let version = "pp-store 1\n"
let versioned = [Objects; Traces; Fenced_specs; Procs]
let nonempty t kind = list t kind <> []
let wipe t kind =
  List.iter (fun name ->
    let target = path t kind name in
    try
      if Sys.is_directory target then begin
        Array.iter (fun child -> Sys.remove (Filename.concat target child))
          (Sys.readdir target);
        Unix.rmdir target
      end else Sys.remove target
    with _ -> ())
    (list t kind)
let init t =
  ensure_area t Objects; ensure_area t Traces;
  let version_path = Filename.concat t.root "VERSION" in
  match read version_path with
  | Some current when current = version -> ()
  | _ ->
      if List.exists (nonempty t) versioned then begin
        prerr_endline ("pp: store format changed — clearing cached objects/traces under "
          ^ t.root ^ " (blobs and journal kept); everything recomputes on first use");
        List.iter (wipe t) versioned
      end;
      atomic_replace version_path version
