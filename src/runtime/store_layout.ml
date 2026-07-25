open Pp_kernel
open Source_error

type t = { root : string }
type area = Objects | Traces | Blobs | Fenced_specs | Procs | Locks

let default = {
  root = Filename.concat (Option.value (Sys.getenv_opt "HOME") ~default:"/tmp") ".pp/store"
}
let root t = t.root
let area_name = function
  | Objects -> "objects" | Traces -> "traces" | Blobs -> "blobs"
  | Fenced_specs -> "fenced-specs" | Procs -> "procs" | Locks -> "locks"
let area t kind = Filename.concat t.root (area_name kind)
let path t kind name = Filename.concat (area t kind) name

let best_effort f = try f () with _ -> ()

let rec ensure_dir_raw dir =
  if dir = "" || dir = "." || dir = Filename.dirname dir then ()
  else
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
        ensure_dir_raw (Filename.dirname dir);
        (try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())
let ensure_dir dir =
  try ensure_dir_raw dir with
  | Unix.Unix_error (error, _, _) ->
      raise (Error (Store (Write_failed {
        path = dir; message = Unix.error_message error })))
let ensure_area t kind = ensure_dir (area t kind)
let list t kind =
  let dir = area t kind in
  if Sys.file_exists dir then Array.to_list (Sys.readdir dir) else []
let read path =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (really_input_string ic (in_channel_length ic)))
  with
  | Sys_error _ | Unix.Unix_error _ | End_of_file -> None

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
let atomic_replace_raw path content =
  incr write_count; maybe_crash "before";
  let process_id = try Unix.getpid () with _ -> 0 in
  let tmp = path ^ ".tmp." ^ string_of_int process_id ^ "." ^ string_of_int !write_count in
  let oc = open_out_bin tmp in
  let renamed = ref false in
  Fun.protect
    ~finally:(fun () ->
      close_out_noerr oc;
      if not !renamed then best_effort (fun () -> Sys.remove tmp))
    (fun () ->
      output_string oc content;
      maybe_crash "mid";
      close_out oc;
      maybe_crash "pre-rename";
      Sys.rename tmp path;
      renamed := true;
      maybe_crash "post-rename")

let atomic_replace path content =
  try atomic_replace_raw path content with
  | Sys_error message ->
      raise (Error (Store (Write_failed { path; message })))
  | Unix.Unix_error (error, _, _) ->
      raise (Error (Store (Write_failed {
        path; message = Unix.error_message error })))

let version = "pp-store 1\n"
let versioned = [Objects; Traces; Fenced_specs; Procs]
let nonempty t kind = list t kind <> []
let wipe t kind =
  List.iter (fun name ->
    let target = path t kind name in
    best_effort (fun () ->
      if Sys.is_directory target then begin
        Array.iter (fun child -> Sys.remove (Filename.concat target child))
          (Sys.readdir target);
        Unix.rmdir target
      end else Sys.remove target))
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
