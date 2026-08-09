open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let private_mode path =
  let bits = (Unix.stat path).Unix.st_perm land 0o077 in
  check (bits = 0) ("private state path is group/world accessible: " ^ path)

let tree_value entries =
  Core_model.VMap [Core_model.VKeyword "tree", Core_model.VMap entries]

let file blob mode =
  Core_model.VMap [
    Core_model.VKeyword "kind", Core_model.VKeyword "file";
    Core_model.VKeyword "mode", Core_model.VInt mode;
    Core_model.VKeyword "blob", Core_model.VString blob;
  ]

let () =
  let root = Filename.temp_file "pp-repository-unit-" "" in
  Sys.remove root;
  at_exit (fun () -> Fswalk.remove_tree root);
  let layout = Store_layout.of_root root in
  Store_layout.init layout;
  let objects = Object_repository.create layout in
  List.iter (fun kind -> private_mode (Filename.dirname (Store_layout.path layout kind "sentinel")))
    [Store_layout.Objects; Store_layout.Traces];
  private_mode root;
  private_mode (Filename.concat root "VERSION");
  let runtime = Runtime_context.create ~layout () in
  let value = Core_model.VInt 42 in
  let key = Identity.hash_value value in
  Object_repository.put objects ~key ~value;
  check (Object_repository.get objects ~key = Some value)
    "object repository did not return its value";
  let object_path = Store_layout.path layout Store_layout.Objects key in
  let wrong_value = Core_model.VString "valid but wrongly addressed" in
  let wrong_bytes =
    match Codec.encode_value wrong_value with
    | Some bytes -> bytes
    | None -> failwith "test object did not encode"
  in
  Store_layout.atomic_replace object_path wrong_bytes;
  check (Object_repository.get objects ~key = None)
    "object repository served a valid value under the wrong key";
  Object_repository.put objects ~key ~value;
  check (Object_repository.get objects ~key = Some value)
    "object repository did not repair a wrongly addressed value";
  (match Object_repository.put objects ~key ~value:wrong_value with
   | () -> failwith "object repository accepted a mismatched key"
   | exception Invalid_argument _ -> ());
  let fenced_value =
    Core_model.VMap [Core_model.VKeyword "command", Core_model.VString "safe"]
  in
  let fenced_hash = Identity.hash_value fenced_value in
  Object_repository.put_fenced objects ~hash:fenced_hash fenced_value;
  let fenced_path =
    Store_layout.path layout Store_layout.Fenced_specs fenced_hash
  in
  Store_layout.atomic_replace fenced_path wrong_bytes;
  check (Object_repository.get_fenced objects ~hash:fenced_hash = None)
    "fenced repository served a wrongly addressed action";
  Object_repository.put_fenced objects ~hash:fenced_hash fenced_value;
  check
    (Object_repository.get_fenced objects ~hash:fenced_hash = Some fenced_value)
    "fenced repository did not repair a wrongly addressed action";
  let blob = String.make 64 'a' in
  let tree = tree_value [
    Core_model.VString "bin",
      Core_model.VMap [
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
  let blobs = Blob_repository.create layout in
  let stored_blob = Blob_repository.put blobs bytes in
  let blob_path = Store_layout.path layout Store_layout.Blobs stored_blob in
  let oc = open_out_bin blob_path in
  output_string oc "corrupt";
  close_out oc;
  check (Blob_repository.get blobs stored_blob = None)
    "blob repository served corrupt bytes";
  let repaired_blob = Blob_repository.put blobs bytes in
  check (repaired_blob = stored_blob &&
         Blob_repository.get blobs stored_blob = Some bytes)
    "blob repository did not repair corrupt bytes";
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
      let round_trip =
        Runtime_context.with_current runtime
          (fun () ->
            Artifact_store.materialize ~root:materialized portable;
            Artifact_store.snapshot ~root:materialized
              ~paths:["bin"; "empty"; "latest"]) ()
      in
      let actual = Artifact_tree.to_value round_trip in
      let expected = Artifact_tree.to_value portable in
      check (actual = expected)
        ("tree materialization and snapshot did not round-trip: "
         ^ Presentation.string_of_value actual ^ " <> "
         ^ Presentation.string_of_value expected));
  let cache_key = Identity_types.Cache_key.of_digest key in
  let result_hash = Identity_types.Object_hash.of_digest key in
  let cell = Identity_types.Cell_id.of_string "runtime-file:p" in
  let observed =
    Identity_types.Observed_hash.of_digest (Hasher.hash_string "observed") in
  let traces = Trace_repository.create layout in
  Trace_repository.put traces ~key:cache_key ~outcome:Trace_repository.Ok
    ~result_hash ~reads:[cell, observed];
  Runtime_context.with_current runtime (fun () -> Journal.append (Journal.Exec ["true"])) ();
  private_mode (Filename.concat (Store_layout.root layout) "journal");
  private_mode (Filename.concat (Store_layout.root layout) "journal/log");
  private_mode (Filename.dirname (Store_layout.path layout Store_layout.Locks "sentinel"));
  private_mode
    (Store_layout.path layout Store_layout.Locks
       (Identity_types.Cache_key.to_string cache_key));
  let trace_path =
    Store_layout.path layout Store_layout.Traces
      (Identity_types.Cache_key.to_string cache_key) in
  let valid_line = Trace_repository.to_line
      { Trace_repository.outcome = Trace_repository.Ok;
        result_hash; reads = [cell, observed] } in
  let malformed_lines = [
    "(trace ok \"bad\" ())";
    Printf.sprintf "(trace ok \"%s\" ((\"runtime-file:p\" . \"bad\")))" key;
    Printf.sprintf "(trace ok \"%s\" ((\"\" . \"%s\")))" key
      (Hasher.hash_string "observed");
    Printf.sprintf "(trace ok \"%s\" ((\"%c\" . \"%s\")))" key (Char.chr 1)
      (Hasher.hash_string "observed");
  ] in
  let oc = open_out trace_path in
  List.iter (fun line -> output_string oc (line ^ "\n")) malformed_lines;
  output_string oc (valid_line ^ "\n");
  close_out oc;
  match Trace_repository.load traces ~key:cache_key with
  | [{ Trace_repository.outcome = Trace_repository.Ok; result_hash = got; reads = [_] }] ->
      check (Identity_types.Object_hash.to_string got = key) "trace result hash changed";
      let fallback_key =
        Identity_types.Cache_key.of_digest "valid-trace-after-corrupt-trace"
      in
      Trace_repository.put traces ~key:fallback_key
        ~outcome:Trace_repository.Ok
        ~result_hash:(Identity_types.Object_hash.of_digest
          (Hasher.hash_string "missing"))
        ~reads:[];
      Trace_repository.put traces ~key:fallback_key
        ~outcome:Trace_repository.Ok ~result_hash ~reads:[];
      let policy = Cache_policy.create () in
      check
        (Cache_policy.lookup policy ~traces ~objects ~blobs
           ~observe_id:(fun _ -> None) ~replay:(fun _ -> ())
           ~key:fallback_key ~authorized:(fun _ -> true) =
         Cache_policy.HitOk value)
        "cache did not skip a corrupt trace result for a later valid trace";
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
