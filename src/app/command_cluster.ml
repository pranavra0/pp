open Pp_runtime
open Pp_kernel
open Source_error
let read_raw path = Cell_repository.read_raw path

let run_transport direction (kind, id, root) =
  match direction, kind with
  | `Push, "object" -> Transport.LocalDir.push_object root ~hash:id
  | `Push, "blob" -> Transport.LocalDir.push_blob root ~hash:id
  | `Push, "trace" -> Transport.LocalDir.push_trace root ~key:id
  | `Pull, "object" -> Transport.LocalDir.pull_object root ~hash:id
  | `Pull, "blob" -> Transport.LocalDir.pull_blob root ~hash:id
  | `Pull, "trace" -> Transport.LocalDir.pull_trace root ~key:id
  | _, _ -> command (Printf.sprintf "pp --transport-%s: unknown artifact kind %s"
    (match direction with `Push -> "push" | `Pull -> "pull") kind)

let cluster_init host =
  Store_layout.ensure_dir (Cap_token.cluster_dir host);
  if Sys.file_exists (Cap_token.secret_path host) then
    command (Printf.sprintf
      "pp cluster-init: a cluster secret already exists at %s — refusing to overwrite (this would invalidate every token already minted against it); remove it by hand first if you really mean to rotate"
      (Cap_token.secret_path host));
  let secret = Hasher.hex_encode (Cryptokit.Random.string Cryptokit.Random.secure_rng 32) in
  Cap_token.write_secret_file host (Cap_token.secret_path host) (secret ^ "\n");
  let cluster_id = Hasher.hex_encode (Cryptokit.Random.string Cryptokit.Random.secure_rng 16) in
  if not (Sys.file_exists (Cap_token.id_path host)) then
    Store_layout.atomic_replace (Cap_token.id_path host) (cluster_id ^ "\n");
  Printf.printf
    "pp cluster-init: minted %s (mode 0600) and cluster id %s\npp cluster-init: distribute BOTH files to other cluster members out of band, at the same path (~/.pp/cluster/) — pp never transmits them\n"
    (Cap_token.secret_path host) cluster_id

let run_admin ctx cli =
  let host = App_context.host ctx in
  if Cli.cluster_init cli then (cluster_init host; true)
  else match Cli.mint_token cli with
    | Some (out, ttl) ->
        let secret = Cap_token.load_secret host in
        let cluster_id = Cap_token.load_cluster_id host in
        Store_layout.atomic_replace out
          (Cap_token.mint host ~secret ~cluster_id
             ~specs:(Cli.grants cli) ~ttl_seconds:ttl);
        true
    | None -> match Cli.transport_push cli with
      | Some args -> run_transport `Push args; true
      | None -> match Cli.transport_pull cli with
        | Some args -> run_transport `Pull args; true
        | None -> match Cli.serve_hit cli with
          | Some (key, token_file, shared_root, reply_file) ->
              let token_text = read_raw token_file in
              let reply = Dynamic_scope.with_top_level
                (App_context.session ctx) (App_context.invocation ctx)
                ~f:(fun () -> Transport.serve_hit (App_context.host ctx)
                  ~key ~token_text ~shared_root) () in
              Store_layout.atomic_replace reply_file reply;
              true
          | None -> match Cli.recv_hit cli with
          | Some (reply_file, shared_root) ->
              (match Transport.recv_hit ~reply_text:(read_raw reply_file) ~shared_root with
               | Transport.RHit { key; result_hash; _ } ->
                   Printf.printf "recv-hit: hit key=%s result=%s\n" key result_hash
               | Transport.RMiss key -> Printf.printf "recv-hit: miss key=%s\n" key
               | Transport.RDeny (key, reason) ->
                   Printf.printf "recv-hit: deny key=%s reason=%s\n" key reason);
              true
          | None -> false

let prepare ctx cli =
  (match Cli.gc_mark_out cli with Some _ -> Cache_policy.begin_gc Cache_policy.default | None -> ());
  (match Cli.desired_object cli with
   | Some (hash, root) ->
       Transport.LocalDir.pull_object root ~hash;
       (match Object_repository.get Object_repository.default ~key:hash with
        | Some value -> List.iter (fun blob ->
            try Transport.LocalDir.pull_blob root ~hash:blob with _ -> ())
            (Blobref.blob_refs_in value)
        | None -> ())
   | None -> ());
  (match Cli.remote_node cli with
   | Some (_, pins, _, _, _) -> Remote.preseed_pins_from_file (App_context.session ctx) ~pins_file:pins
   | None -> ());
  (match Cli.pin_file cli with
   | Some pins -> Remote.preseed_pins_from_file (App_context.session ctx) ~pins_file:pins
   | None -> ())

let serve_remote ctx cli =
  match Cli.remote_node cli with
  | None -> ()
  | Some (token_file, _, shared_root, keys_file, reply_file) ->
      let token_text = read_raw token_file in
      Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
        ~f:(fun () -> Remote.serve_assigned_keys (App_context.host ctx)
          ~token_text ~keys_file ~shared_root ~reply_file) ()

let publish ctx cli =
  match Cli.publish_object_root cli with
  | None -> ()
  | Some shared_root ->
      Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
        ~f:(fun () ->
          match Command_run.run_files ctx cli (Cli.files cli) with
          | None -> command "pp: --publish-object: the program produced no value"
          | Some value ->
              let forced = Force_deep.force_deep value in
              let hash = Identity.hash_value forced in
              (match Codec.encode_value forced with
               | None -> command "pp: --publish-object: the program's value contains code (a closure/thunk/handle) and cannot be published as data"
               | Some _ -> Object_repository.put Object_repository.default ~key:hash ~value:forced);
              List.iter (fun blob ->
                try Transport.LocalDir.push_blob shared_root ~hash:blob with _ -> ())
                (Blobref.blob_refs_in forced);
              Transport.LocalDir.push_object shared_root ~hash;
              Printf.printf "publish-object: %s\n" hash) ()
