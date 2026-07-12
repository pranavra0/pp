(* pp filesystem-domain reconciler v1 (DESIGN Q4, SPEC LAW 30).

   The program is a pure function from input cells to a DESIRED-STATE value;
   the reconciler is the domain's single writer. For the filesystem domain:
   the program's final value is a map of relative paths to string contents,
   and `pp --reconcile ROOT prog.pp` makes the tree under ROOT match it:

     plan   — diff desired against observed (content hashes);
     journal— append `intent <desired-hash> ...` to ~/.pp/store/journal,
              apply, then append `done <desired-hash>` (Q4: recovery is
              re-running reconcile — desired is cheap to recompute, observed
              is re-derived from reality — the journal is the audit trail);
     apply  — temp file + rename(2) in the target directory (atomic),
              parents created; files under ROOT not in the desired map are
              deleted and emptied directories pruned (single writer: the
              domain is managed, the write grant is the consent);
     verify — every written file is re-read and hash-compared after write.

   Authority: an fs WRITE grant covering ROOT (LAW 22/23).
   Stratification (LAW 30): if evaluating the program observed any file:/
   tree: cell under ROOT, reconciling is refused — a desired state that reads
   its own domain never converges. *)

open Types

let strip_prefix prefix s =
  let plen = String.length prefix in
  if String.length s >= plen && String.sub s 0 plen = prefix then
    Some (String.sub s plen (String.length s - plen))
  else None

let strip_suffix suffix s =
  let slen = String.length suffix in
  let n = String.length s in
  if n >= slen && String.sub s (n - slen) slen = suffix then
    Some (String.sub s 0 (n - slen))
  else None

(* Component-boundary "is [path] under [root]" — "/out" covers "/out/a" but
   not "/output" (Paths.under, the one shared containment predicate). *)
let under_root ~(root : string) (path : string) : bool =
  Paths.under ~root path

(* Relative output paths only, no traversal: the desired map cannot name
   anything outside its domain. *)
let validate_rel (rel : string) : unit =
  if rel = "" then failwith "reconcile: empty path in desired map";
  if not (Filename.is_relative rel) then
    failwith ("reconcile: desired paths must be relative to the domain root: " ^ rel);
  List.iter (fun part ->
    if part = ".." then
      failwith ("reconcile: '..' not allowed in desired path: " ^ rel))
    (String.split_on_char '/' rel)

(* Observed reality: every regular file under [root] as (rel-path, hash). *)
let observed_files (root : string) : (string * string) list =
  let acc = ref [] in
  let rec walk dir rel =
    match Sys.readdir dir with
    | exception _ -> ()
    | names ->
        Array.iter (fun name ->
          let p = Filename.concat dir name in
          let r = if rel = "" then name else rel ^ "/" ^ name in
          match Unix.lstat p with
          | exception _ -> ()
          | { Unix.st_kind = Unix.S_DIR; _ } -> walk p r
          | { Unix.st_kind = Unix.S_REG; _ } ->
              (match Store.hash_file_opt p with
               | Some h -> acc := (r, h) :: !acc
               | None -> ())
          | _ -> ())
          names
  in
  if Sys.file_exists root && Sys.is_directory root then walk root "";
  !acc

let rec mkdir_p dir =
  if not (Sys.file_exists dir) then begin
    (try mkdir_p (Filename.dirname dir) with _ -> ());
    try Unix.mkdir dir 0o755 with
    | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

(* Atomic materialization: temp file in the TARGET directory + rename, so a
   crash never leaves a half-written file at the destination. *)
let write_atomic (path : string) (content : string) : unit =
  mkdir_p (Filename.dirname path);
  let tmp = path ^ ".pp-tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  (try output_string oc content
   with exn -> close_out oc; (try Sys.remove tmp with _ -> ()); raise exn);
  close_out oc;
  Unix.rename tmp path

(* Remove now-empty directories left behind by a delete, up to (not
   including) the domain root. *)
let rec prune_empty_dirs ~root dir =
  if under_root ~root dir && dir <> root then
    match Sys.readdir dir with
    | [||] -> (try Unix.rmdir dir with _ -> ());
              prune_empty_dirs ~root (Filename.dirname dir)
    | _ -> ()
    | exception _ -> ()

let reconcile ~(root : string) (desired_val : value) : unit =
  (* SPEC LAW 23 / DESIGN §2.1: canonicalize once, up front, so the write
     grant check, the stratification comparison against recorded file:/tree:
     cells (themselves canonical), and every write path agree — a domain
     root spelled via a symlink or not yet existing is one identity. *)
  let root = Runtime.canonical_path root in
  let force = !Runtime.force_hook in
  (* Single writer needs the authority to write the whole domain. *)
  if not (List.exists (fun cap -> Capabilities.check_fs_write cap root)
            !Runtime.current_capabilities) then
    raise (Capability_error
             ("capability error: no write access for domain root " ^ root));
  (* Stratification (LAW 30): desired state may not read its own domain. *)
  List.iter (fun (cell, _) ->
    match Cell.of_string cell with
    | (Cell.File p | Cell.Tree p) when under_root ~root p ->
        failwith ("reconcile: stratification violation (LAW 30): the desired \
                   state observed its own domain: " ^ cell)
    | _ -> ())
    !Runtime.observed_all;
  (* The desired map: relative path -> string content, forced. *)
  let kvs = match force desired_val with
    | VMap kvs -> kvs
    | _ -> failwith "reconcile: the program must return a map of relative \
                     paths to string contents"
  in
  let desired = List.map (fun (k, v) ->
    let rel = match force k with
      | VString s | VKeyword s -> s
      | other -> failwith ("reconcile: desired key must be a string, got "
                           ^ string_of_value other)
    in
    validate_rel rel;
    let content = match force v with
      | VString s -> s
      | other -> failwith ("reconcile: desired content for " ^ rel
                           ^ " must be a string, got " ^ string_of_value other)
    in
    (rel, content)) kvs
  in
  (* A desired content is either inline bytes or a CAS reference
     "blob:<sha256>" (the `blob` primitive), optionally suffixed ":x" to
     materialize with the executable bit (a linked binary). Refs diff by hash
     without loading bytes; bytes are pulled from the store only when a write
     is actually needed — a dangling ref is a hard error. The exec bit is set
     at write time, not converged on mode-only drift (v1). *)
  let blob_ref (c : string) : (string * bool) option =
    match strip_prefix "blob:" c with
    | None -> None
    | Some rest ->
        (match strip_suffix ":x" rest with
         | Some h -> Some (h, true)
         | None -> Some (rest, false))
  in
  let content_hash (c : string) : string =
    match blob_ref c with
    | Some (h, _) -> h
    | None -> hash_string c
  in
  let content_bytes (rel : string) (c : string) : string =
    match blob_ref c with
    | Some (h, _) ->
        (match Store.load_blob h with
         | Some bytes -> bytes
         | None -> failwith ("reconcile: blob missing from store for " ^ rel
                             ^ ": " ^ h))
    | None -> c
  in
  let content_executable (c : string) : bool =
    match blob_ref c with Some (_, x) -> x | None -> false
  in
  let desired_hash =
    hash_concat ("desired-fs"
                 :: List.concat_map (fun (r, c) -> [r; content_hash c])
                      (List.sort compare desired))
  in
  (* Plan: diff desired against observed reality. *)
  let observed = observed_files root in
  let creates, updates, unchanged =
    List.fold_left (fun (cs, us, ns) (rel, content) ->
      match List.assoc_opt rel observed with
      | None -> ((rel, content) :: cs, us, ns)
      | Some h when h = content_hash content -> (cs, us, ns + 1)
      | Some _ -> (cs, (rel, content) :: us, ns))
      ([], [], 0) desired
  in
  let deletes =
    List.filter (fun (rel, _) -> not (List.mem_assoc rel desired)) observed
  in
  (* Journal the intent, apply, mark done (Q4). *)
  Journal.append (Journal.FsIntent {
    hash = desired_hash; root;
    create = List.length creates; update = List.length updates;
    delete = List.length deletes });
  List.iter (fun (rel, content) ->
    let path = Filename.concat root rel in
    write_atomic path (content_bytes rel content);
    if content_executable content then
      (try Unix.chmod path 0o755 with _ -> ());
    (* Verify-after-write: trust reality, not the write call. *)
    match Store.hash_file_opt path with
    | Some h when h = content_hash content -> ()
    | _ -> failwith ("reconcile: verify-after-write failed for " ^ path))
    (creates @ updates);
  List.iter (fun (rel, _) ->
    let path = Filename.concat root rel in
    (try Sys.remove path with _ -> ());
    prune_empty_dirs ~root (Filename.dirname path))
    deletes;
  Journal.append (Journal.FsDone { hash = desired_hash });
  Printf.eprintf "[reconcile] root=%s create=%d update=%d delete=%d unchanged=%d\n%!"
    root (List.length creates) (List.length updates) (List.length deletes)
    unchanged
