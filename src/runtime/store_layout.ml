open Pp_kernel
open Source_error

type t = { root : string }
type area = Objects | Traces | Blobs | Fenced_specs | Procs | Locks

external ensure_dir_one : string -> unit = "pp_store_ensure_dir_one"
external atomic_replace_c : string -> string -> unit = "pp_store_atomic_replace"
external open_append_c : string -> Unix.file_descr = "pp_store_open_append"
external open_rw_c : string -> Unix.file_descr = "pp_store_open_rw"
external open_trunc_c : string -> Unix.file_descr = "pp_store_open_trunc"
external open_read_c : string -> Unix.file_descr = "pp_store_open_read"
external unlink_c : string -> unit = "pp_store_unlink"
external clear_dir_c : string -> unit = "pp_store_clear_dir"

let absolute path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path
let rec canonical_root path =
  if Sys.file_exists path then Unix.realpath path
  else
    let parent = Filename.dirname path in
    if parent = path then path
    else Filename.concat (canonical_root parent) (Filename.basename path)

let of_root root = { root = canonical_root (absolute root) }
let root t = t.root
let area_name = function
  | Objects -> "objects" | Traces -> "traces" | Blobs -> "blobs"
  | Fenced_specs -> "fenced-specs" | Procs -> "procs" | Locks -> "locks"
let area t kind = Filename.concat t.root (area_name kind)
let valid_name name =
  name <> "" && name <> "." && name <> ".."
  && not (String.contains name '/')
  && not (String.contains name '\000')
let path t kind name =
  if not (valid_name name) then invalid_arg "store path must be one name";
  Filename.concat (area t kind) name
let rec ensure_dir_raw dir =
  let dir = absolute dir in
  if dir = "/" then ()
  else try ensure_dir_one dir with
    | Unix.Unix_error (Unix.ENOENT, _, _) ->
        ensure_dir_raw (Filename.dirname dir); ensure_dir_one dir
let ensure_dir dir =
  try ensure_dir_raw dir with
  | Sys_error message -> raise (Error (Store (Write_failed {path=dir; message})))
  | Unix.Unix_error (error, _, _) ->
      raise (Error (Store (Write_failed {path=dir; message=Unix.error_message error})))
let ensure_area t kind = ensure_dir (area t kind)
let list t kind =
  let dir = area t kind in
  if Sys.file_exists dir then Array.to_list (Sys.readdir dir) else []
let read path =
  try let ic = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (really_input_string ic (in_channel_length ic)))
  with Sys_error _ | Unix.Unix_error _ | End_of_file -> None
let crash_spec = lazy (match Sys.getenv_opt "PP_CRASH_AT" with
  | Some value -> (match String.split_on_char ':' value with
      | [boundary; count] -> Option.map (fun n -> boundary,n) (int_of_string_opt count)
      | _ -> None)
  | None -> None)
let write_count = ref 0
let maybe_crash boundary = match Lazy.force crash_spec with
  | Some (expected,count) when expected=boundary && !write_count=count -> Unix.kill (Unix.getpid ()) Sys.sigkill
  | _ -> ()
let atomic_replace path content =
  incr write_count; maybe_crash "before";
  try atomic_replace_c (absolute path) content; maybe_crash "post-rename" with
  | Sys_error message -> raise (Error (Store (Write_failed {path;message})))
  | Unix.Unix_error (error,_,_) ->
      raise (Error (Store (Write_failed {path;message=Unix.error_message error})))
let open_append path = open_append_c (absolute path)
let open_rw path = open_rw_c (absolute path)
let open_trunc path = open_trunc_c (absolute path)
let open_read path = open_read_c (absolute path)
let read_store path =
  try
    let fd = open_read path in
    let ic = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr ic)
      (fun () -> Some (really_input_string ic (in_channel_length ic)))
  with Sys_error _ | Unix.Unix_error _ | End_of_file -> None
let remove path =
  try unlink_c (absolute path) with Unix.Unix_error (Unix.ENOENT,_,_) -> ()
let clear_dir path = clear_dir_c (absolute path)
let version = "pp-store 2\n"
let versioned = [Objects; Traces; Fenced_specs; Procs]
let nonempty t kind = list t kind <> []
let init t =
  ensure_area t Objects; ensure_area t Traces;
  let version_path = Filename.concat t.root "VERSION" in
  match read_store version_path with
  | Some current when current = version -> ()
  | _ ->
      if List.exists (nonempty t) versioned then begin
        List.iter (ensure_area t) versioned;
        prerr_endline ("pp: store format changed — clearing cached objects/traces under " ^ t.root ^ " (blobs and journal kept); everything recomputes on first use");
        List.iter (fun kind -> clear_dir (area t kind)) versioned
      end;
      atomic_replace version_path version
let with_lifecycle ~layout command f =
  ensure_area layout Locks;
  let path = path layout Locks "lifecycle" in
  let fd = open_rw path in
  Fun.protect ~finally:(fun () -> (try Unix.lockf fd Unix.F_ULOCK 0 with Unix.Unix_error _ -> ()); Unix.close fd)
    (fun () -> Unix.lockf fd command 0; f ())
let with_lifecycle_read ~layout f = with_lifecycle ~layout Unix.F_RLOCK f
let with_lifecycle_write ~layout f = with_lifecycle ~layout Unix.F_LOCK f
