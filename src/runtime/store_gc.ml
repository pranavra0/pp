open Pp_kernel

let default_grace_seconds = 2.0

let mark_object live hash =
  Hashtbl.replace live ("object:" ^ hash) ();
  match Object_repository.get Object_repository.default ~key:hash with
  | None -> ()
  | Some value ->
      List.iter
        (fun blob -> Hashtbl.replace live ("blob:" ^ blob) ())
        (Artifact_tree.reachable_blobs value)

let mark_graph roots =
  let live = Hashtbl.create 1024 in
  let visited = Hashtbl.create 256 in
  let rec mark_node key =
    let key_text = Identity_types.Node_key.to_string key in
    if not (Hashtbl.mem visited key_text) then begin
      Hashtbl.replace visited key_text ();
      Hashtbl.replace live ("trace:" ^ key_text) ();
      Trace_repository.load Trace_repository.default
        ~key:(Identity_types.Cache_key.of_node_key key)
      |> List.iter (fun trace ->
           mark_object live
             (Identity_types.Object_hash.to_string trace.Trace_repository.result_hash);
           List.iter (fun (cell, hash) ->
             match Cell.parse (Identity_types.Cell_id.to_string cell) with
             | Cell.Node child ->
                 mark_node (Identity_types.Node_key.of_string child)
             | Cell.File _ ->
                 Hashtbl.replace live
                   ("blob:" ^ Identity_types.Observed_hash.to_string hash) ()
             | _ -> ())
             trace.Trace_repository.reads)
    end
  in
  List.iter (fun root ->
    mark_object live root.Gcroots.gr_hash;
    List.iter mark_node root.Gcroots.gr_nodes)
    roots;
  live

let manifest_snapshot () =
  let path = Gcroots.roots_path () in
  if Sys.file_exists path then Some (Cell_repository.read_raw path) else None

let sweep kind prefix live grace_seconds snapshot aborted =
  let now = Unix.gettimeofday () in
  List.fold_left (fun (kept, deleted) entry ->
      if Hashtbl.mem live (prefix ^ entry.Repository_inventory.id) then
        kept + 1, deleted
      else
        let young =
          match entry.Repository_inventory.modified with
          | Some modified -> now -. modified < grace_seconds
          | None -> true
        in
        if young || !aborted then kept + 1, deleted
        else if manifest_snapshot () <> snapshot then begin
          aborted := true;
          Printf.eprintf
            "pp gc: wanted roots changed mid-sweep; stopping deletes\n%!";
          kept + 1, deleted
        end else begin
          Repository_inventory.remove kind entry.Repository_inventory.id;
          kept, deleted + 1
        end)
    (0, 0) (Repository_inventory.entries kind)

let run ~grace_seconds =
  let roots = Gcroots.read_all () in
  if roots = [] then
    Printf.printf
      "pp gc: no wanted roots; nothing to do\n"
  else
    let live = mark_graph roots in
    Store_layout.with_lifecycle_write (fun () ->
      let snapshot = manifest_snapshot () in
      let aborted = ref false in
      let ko, do_ =
        sweep Repository_inventory.Object "object:" live grace_seconds snapshot aborted in
      let kt, dt =
        sweep Repository_inventory.Trace "trace:" live grace_seconds snapshot aborted in
      let kb, db =
        sweep Repository_inventory.Blob "blob:" live grace_seconds snapshot aborted in
      Printf.printf
        "pp gc: objects kept=%d deleted=%d, traces kept=%d deleted=%d, blobs kept=%d deleted=%d\n"
        ko do_ kt dt kb db)
