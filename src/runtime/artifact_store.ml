open Pp_kernel

let read_blob hash =
  match Blob_repository.get (Runtime_context.blobs ()) hash with
  | Some content when Hasher.hash_string content = hash -> content
  | Some _ -> failwith ("tree blob hash mismatch: " ^ hash)
  | None -> failwith ("tree blob is missing: " ^ hash)

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    ensure_dir (Filename.dirname path);
    Unix.mkdir path 0o700
  end

let write_file path content mode =
  ensure_dir (Filename.dirname path);
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel content);
  Unix.chmod path mode

let materialize ~root tree =
  List.iter (function
    | Artifact_tree.Directory { path; mode } ->
        let target = Filename.concat root path in
        ensure_dir (Filename.dirname target);
        Unix.mkdir target mode
    | Artifact_tree.File { path; mode; blob } ->
        write_file (Filename.concat root path) (read_blob blob) mode
    | Artifact_tree.Symlink { path; target } ->
        let destination = Filename.concat root path in
        ensure_dir (Filename.dirname destination);
        Unix.symlink target destination)
    tree

let verify tree = List.iter (fun hash -> ignore (read_blob hash)) (Artifact_tree.blob_hashes tree)

let relative_path path =
  path <> ""
  && Filename.is_relative path
  && not (String.contains path '\000')
  && List.for_all (fun part -> part <> "" && part <> "." && part <> "..")
       (String.split_on_char '/' path)

let snapshot ~root ~paths =
  let selected = List.sort_uniq String.compare paths in
  List.iter (fun path ->
    if not (relative_path path) then failwith ("non-canonical selected output path: " ^ path))
    selected;
  let entries = Hashtbl.create 32 in
  let add entry =
    let path = match entry with
      | Artifact_tree.File { path; _ }
      | Artifact_tree.Directory { path; _ }
      | Artifact_tree.Symlink { path; _ } -> path
    in
    Hashtbl.replace entries path entry
  in
  let rec add_parents path =
    let parent = Filename.dirname path in
    if parent <> "." && not (Hashtbl.mem entries parent) then begin
      let stat = Unix.lstat (Filename.concat root parent) in
      if stat.Unix.st_kind <> Unix.S_DIR then
        failwith ("selected output has a non-directory parent: " ^ path);
      add_parents parent;
      add (Artifact_tree.Directory { path = parent; mode = stat.Unix.st_perm land 0o777 })
    end
  in
  let rec walk path =
    let source = Filename.concat root path in
    let stat =
      try Unix.lstat source
      with Unix.Unix_error _ -> failwith ("selected output is missing: " ^ path)
    in
    add_parents path;
    match stat.Unix.st_kind with
    | Unix.S_REG ->
        let content = Cell_repository.read_raw source in
        let blob = Blob_repository.put (Runtime_context.blobs ()) content in
        add (Artifact_tree.File { path; mode = stat.Unix.st_perm land 0o777; blob })
    | Unix.S_DIR ->
        add (Artifact_tree.Directory { path; mode = stat.Unix.st_perm land 0o777 });
        Sys.readdir source
        |> Array.to_list
        |> List.sort String.compare
        |> List.iter (fun child -> walk (path ^ "/" ^ child))
    | Unix.S_LNK ->
        add (Artifact_tree.Symlink { path; target = Unix.readlink source })
    | _ -> failwith ("selected output has an unsupported entry kind: " ^ path)
  in
  List.iter walk selected;
  let tree = Hashtbl.to_seq_values entries
  |> List.of_seq
  |> List.sort (fun a b ->
       let path = function
         | Artifact_tree.File { path; _ }
         | Artifact_tree.Directory { path; _ }
         | Artifact_tree.Symlink { path; _ } -> path
       in
       String.compare (path a) (path b))
  in
  Artifact_tree.validate tree;
  tree
