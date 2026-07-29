open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let tree_value entries =
  Value.map [Core_model.VKeyword "tree", Value.map entries]

let file blob mode =
  Value.map [
    Core_model.VKeyword "kind", Core_model.VKeyword "file";
    Core_model.VKeyword "mode", Core_model.VInt mode;
    Core_model.VKeyword "blob", Core_model.VString blob;
  ]

let () =
  let layout = Store_layout.default in
  Store_layout.init layout;
  let objects = Object_repository.create layout in
  let key = Identity.hash_value (Core_model.VString "repository") in
  Object_repository.put objects ~key ~value:(Core_model.VInt 42);
  check (Object_repository.get objects ~key = Some (Core_model.VInt 42))
    "object repository did not return its value";
  let blob = String.make 64 'a' in
  let tree = tree_value [
    Core_model.VString "bin",
      Value.map [
        Core_model.VKeyword "kind", Core_model.VKeyword "directory";
        Core_model.VKeyword "mode", Core_model.VInt 0o755;
      ];
    Core_model.VString "bin/tool", file blob 0o755;
  ] in
  (match Artifact_tree.of_value tree with
   | Ok parsed ->
       check (Artifact_tree.blob_hashes parsed = [blob])
         "canonical tree did not expose its blob edge"
   | Error message -> failwith message);
  check (Artifact_tree.reachable_blobs
           (Core_model.VVector [|Core_model.VString ("blob:" ^ blob); tree|]) = [blob])
    "tree reachability scanned an incidental blob-looking string";
  (match Artifact_tree.of_value (tree_value [
           Core_model.VString "../escape", file blob 0o644]) with
   | Error _ -> ()
   | Ok _ -> failwith "tree accepted an escaping path");
  (match Artifact_tree.of_value (tree_value [
           Core_model.VString "missing/file", file blob 0o644]) with
   | Error _ -> ()
   | Ok _ -> failwith "tree accepted a missing parent directory");
  let bytes = "portable tree bytes" in
  let stored_blob = Blob_repository.put Blob_repository.default bytes in
  let portable = [
    Artifact_tree.Directory { path = "bin"; mode = 0o755 };
    Artifact_tree.File { path = "bin/tool"; mode = 0o755; blob = stored_blob };
    Artifact_tree.Directory { path = "empty"; mode = 0o700 };
    Artifact_tree.Symlink { path = "latest"; target = "bin/tool" };
  ] in
  let materialized = Filename.temp_file "pp-tree-unit-" "" in
  Sys.remove materialized;
  Unix.mkdir materialized 0o700;
  Fun.protect
    ~finally:(fun () -> Fswalk.remove_tree materialized)
    (fun () ->
      Artifact_store.materialize ~root:materialized portable;
      let round_trip =
        Artifact_store.snapshot ~root:materialized ~paths:["bin"; "empty"; "latest"]
      in
      check (Artifact_tree.to_value round_trip = Artifact_tree.to_value portable)
        "tree materialization and snapshot did not round-trip");
  let cache_key = Identity_types.Cache_key.of_digest key in
  let result_hash = Identity_types.Object_hash.of_digest key in
  let cell = Identity_types.Cell_id.of_string "runtime-file:p" in
  let observed = Identity_types.Observed_hash.of_digest "observed" in
  let traces = Trace_repository.create layout in
  Trace_repository.put traces ~key:cache_key ~outcome:Trace_repository.Ok
    ~result_hash ~reads:[cell, observed];
  match Trace_repository.load traces ~key:cache_key with
  | [{ Trace_repository.outcome = Trace_repository.Ok; result_hash = got; reads = [_] }] ->
      check (Identity_types.Object_hash.to_string got = key) "trace result hash changed";
      let file_pin = Remote_protocol.encode_file_pin ~cell:"file:/tmp/input" ~hash:"abc" in
      check
        (Remote_protocol.decode_pin file_pin =
         Ok (Remote_protocol.File_pin { cell = "file:/tmp/input"; hash = "abc" }))
        "file pin protocol did not round-trip";
      let probe_pin =
        match Remote_protocol.encode_probe_pin ~name:"clock" (Core_model.VInt 7) with
        | Ok pin -> pin
        | Error message -> failwith message
      in
      check
        (Remote_protocol.decode_pin probe_pin =
         Ok (Remote_protocol.Probe_pin { name = "clock"; value = Core_model.VInt 7 }))
        "probe pin protocol did not round-trip";
      let reply = Remote_protocol.Hit {
        key = "node"; result_hash = "result"; blob_hashes = ["a"; "b"];
      } in
      check
        (Remote_protocol.decode_reply (Remote_protocol.encode_reply reply) = Ok reply)
        "remote reply protocol did not round-trip";
      print_endline "repository: ok"
  | _ -> failwith "trace repository did not persist one trace"
