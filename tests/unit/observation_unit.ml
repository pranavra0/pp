open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let () =
  let ids = [Cell.File "p"; Cell.Env "HOME"; Cell.Argv; Cell.Node "key";
    Cell.Domain {name="d"; sub="x"}] in
  List.iter (fun cell ->
    let text = Cell.serialize cell in
    check (Cell.serialize (Cell.parse text) = text) "cell identity did not round-trip") ids;
  check (Observation.authorized [] (Cell.RuntimeFile "missing"))
    "runtime-file observation should be authority-independent";
  check (not (Observation.authorized [] (Cell.File "/missing")))
    "file observation bypassed capability gating";
  check (not (Observation.authorized [] (Cell.Unknown "future")))
    "unknown observation was authorized";
  check (Observation.env_hash None <> Observation.env_hash (Some ""))
    "environment absence was not distinguished from empty value";
  let make_root prefix =
    let path = Filename.temp_file prefix "" in
    Sys.remove path;
    Unix.mkdir path 0o700;
    path
  in
  let symlink_tree = make_root "pp-observe-link-" in
  let file_tree = make_root "pp-observe-file-" in
  Fun.protect
    ~finally:(fun () ->
      Fswalk.remove_tree symlink_tree;
      Fswalk.remove_tree file_tree)
    (fun () ->
      let content = "c" in
      Unix.symlink content
        (Filename.concat symlink_tree "a");
      let oc = open_out_bin (Filename.concat file_tree "a") in
      Fun.protect
        ~finally:(fun () -> close_out_noerr oc)
        (fun () -> output_string oc content);
      check (Observation.tree_hash symlink_tree <> Observation.tree_hash file_tree)
        "tree hash framing collided for symlink and file entries");
  print_endline "observation: ok"
