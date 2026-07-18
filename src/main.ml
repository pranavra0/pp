(* pp main — entry point for the pp interpreter *)

(* One row per CLI flag/subcommand. The same table drives argument parsing,
   subcommand dispatch (via the refs each handler sets), and `--help`, so the
   parser and the help text cannot disagree.

   [handler] is the honest escape hatch: it receives the tokens AFTER the
   flag name and returns the ones it did not consume, so a fixed-arity flag
   takes its N args off the front while a variadic one (fmt, --schedule,
   --check-kernel-props) consumes whatever it needs — and a terminal
   subcommand simply exits without returning. [arity] is the nominal count of
   consumed args for help/reference; -1 marks a variadic escape-hatch row.
   [internal] hides test/dispatcher seams from `--help`; [doc] is the help
   line (newline-terminated) for the rest. *)
type flag = {
  name : string;
  arity : int;
  doc : string;
  internal : bool;
  handler : string list -> string list;
}

(* CLI subcommand logic, top level rather than nested in `main`: `main` reads
   the flag table, builds the invocation record, then dispatches to these.
   Each reads its run configuration from the invocation record — built once,
   never mutated afterward — not from `main`'s parse-time refs. *)

let read_whole (path : string) : string =
  let ch = open_in_bin path in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch; s

let read_file_content (path : string) : string =
  let ch = open_in path in
  let s = really_input_string ch (in_channel_length ch) in
  close_in ch; s

(* Minimal pp string-literal quoting for embedding an OCaml-computed path
   into synthetic glue source text (reader.ml supports the usual backslash
   and double-quote escapes; anything else passes through) — NOT
   Codec.quote_string, which is a different (store-line) escaping dialect. *)
let pp_quote (s : string) : string =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    if c = '\\' then Buffer.add_string buf "\\\\"
    else if c = '"' then Buffer.add_string buf "\\\""
    else Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

let uses_domains invocation =
  Invocation.program_reconcile_root invocation <> None
  || Invocation.program_supervise invocation

(* Domain driver wiring. `--reconcile ROOT` auto-loads stdlib/domain-fs.pp and
   registers it with a write-cap cap-restrict'd to ROOT, wrapping the
   program's final value as {"fs" -> v}; `--supervise` likewise with
   stdlib/domain-proc.pp, {"proc" -> v}; both compose (the same v feeds both).
   A program that calls register-domain itself needs none of this glue — it
   returns {name -> desired} directly, one evaluation, N domains.

   (source-tag, content) pairs to run BEFORE the user's file(s), under the
   SAME init so the domain registrations they
   perform survive into the user program's evaluation — two SEPARATE
   calls would each reinitialize and wipe the session's domain registry
   (Evaluator.init resets it every fresh run). *)
let stdlib_glue_sources invocation : (string * string) list =
  if not (uses_domains invocation) then []
  else match World_path.stdlib_root () with
    | None ->
        failwith "pp: could not locate the stdlib/ directory next to the running \
                  executable (needed for --reconcile/--supervise's domain-fs.pp/\
                  domain-proc.pp)"
    | Some root ->
        let common = List.map (fun f ->
          ("<stdlib:" ^ f ^ ">", Printf.sprintf "(load %s)\n"
             (pp_quote (Filename.concat root f))))
          ["list.pp"; "map.pp"; "string.pp"]
        in
        let fs_glue = match Invocation.program_reconcile_root invocation with
          | None -> []
          | Some r ->
              let canon = World_path.canonical r in
              (* :wo, not :rw — write-only is the minimum sufficient grant
                 here: a write-only grant must still support a full
                 build+restore cycle, because the single writer reading its
                 OWN managed tree to converge is not a distinct authority
                 concern (Domain_prims.tree_observe accepts read-OR-write for
                 exactly this reason), so the domain's write-cap only needs to
                 hold WRITE; requesting :rw here would make cap-restrict itself
                 reject a write-only grant before the domain ever runs. *)
              [("<domain-glue:fs>", Printf.sprintf
                  "(load %s)\n(register-fs-domain %s (cap-restrict (current-capabilities) %s :wo))\n"
                  (pp_quote (Filename.concat root "domain-fs.pp"))
                  (pp_quote (canon :> string)) (pp_quote (canon :> string)))]
        in
        let proc_glue =
          if not (Invocation.program_supervise invocation) then []
          else
            [("<domain-glue:proc>", Printf.sprintf
                "(load %s)\n(register-proc-domain (current-capabilities))\n"
                (pp_quote (Filename.concat root "domain-proc.pp")))]
        in
        common @ fs_glue @ proc_glue

(* Merge rule for the auto-wrap: --reconcile alone -> {"fs" v}; --supervise
   alone -> {"proc" v}; both -> {"fs" v, "proc" v} (both fed the SAME v). A
   bare register-domain program (neither flag) returns its own {name ->
   desired} directly — [v] unwrapped. *)
let build_all_desired invocation (v : Core_model.value) : Core_model.value =
  let pairs =
    (if Invocation.program_reconcile_root invocation <> None then [(Core_model.VString "fs", v)] else [])
    @ (if Invocation.program_supervise invocation then [(Core_model.VString "proc", v)] else [])
  in
  if pairs <> [] then Core_model.VMap pairs else v

(* Run every given file plus (when needed) the domain-registration glue, under
   ONE init — this is what lets `register-fs-domain`/`register-proc-domain`'s
   registration survive to reach the user's file. Falls back to the untouched
   per-file loop when no domain wiring is needed at all. *)
let run_files ?(retain_thunks = false) invocation (files : string list) : Core_model.value option =
  if uses_domains invocation then
    let sources = stdlib_glue_sources invocation
                  @ List.map (fun f -> (f, read_file_content f)) files in
    match List.rev (Repl.execute_sources ~retain_thunks sources) with
    | v :: _ -> Some v | [] -> None
  else
    List.fold_left (fun _ f ->
      match List.rev (Repl.execute_file ~retain_thunks f) with
      | v :: _ -> Some v | [] -> None) None files

let should_run_domains invocation =
  uses_domains invocation || Domains.any_write_domain_registered ()

(* The by-hash desired-value seam: `--desired-object HASH ROOT` substitutes
   the DERIVATION of the desired-state root entirely — the object was already
   pulled (and its blob: refs with it), so this process never runs a program
   to compute what to converge, only to register domains (run_files still
   executes for that side effect; its RETURN VALUE is discarded here in favor
   of the synced object). Without `--desired-object`, wrap the program's own
   return value via build_all_desired. *)
let compute_all_desired invocation (last : Core_model.value option) : Core_model.value =
  match Invocation.program_desired_object invocation with
  | Some (hash, _) ->
      (match Object_repository.get Object_repository.default ~key:hash with
       | Some v -> v
       | None ->
           failwith (Printf.sprintf
             "pp: --desired-object %s: not found in the local store even \
              after pulling — check the shared root and that it was \
              published there via --publish-object" hash))
  | None ->
      (match last with
       | Some v -> build_all_desired invocation v
       | None -> failwith "reconcile: the program produced no value")

(* Host-qualified domain distribution: host-keying is opt-in ONLY via an
   explicit `--member-name <n>` flag, never inferred from a value's shape.
   Without it, [all_desired] passes through completely unchanged. With it,
   [all_desired] MUST be a map keyed by host name (string or keyword) and this
   indexes exactly one entry, handing the UNCHANGED Domains.run_all only that
   host's own {domain -> desired} slice. *)
let select_member_slice invocation (all_desired : Core_model.value) : Core_model.value =
  match Invocation.program_member_name invocation with
  | None -> all_desired
  | Some name ->
      (match Force_deep.force_deep all_desired with
       | Core_model.VMap kvs ->
           (match List.find_opt (fun (k, _) ->
              match k with
              | Core_model.VString s | Core_model.VKeyword s -> s = name
              | _ -> false)
              kvs
            with
            | Some (_, v) -> v
            | None ->
                failwith (Printf.sprintf
                  "pp: --member-name %s: no such host key in the \
                   desired-state map (host-qualified distribution expects \
                   {host -> {domain -> desired}})" name))
       | other ->
           failwith (Printf.sprintf
             "pp: --member-name %s: desired-state must be a map of \
              host -> {domain -> desired} to index, got %s"
             name (Presentation.string_of_value other)))

let run_domains_pass invocation (last : Core_model.value option) : unit =
  if should_run_domains invocation then begin
    Domains.run_all invocation (select_member_slice invocation (compute_all_desired invocation last));
    Fenced.drain ()
  end

let print_graph ?(verbose = false) () = Store_index.print_graph ~verbose ()

let snapshot_cell_hashes (cell_ids : string list) : (string * string) list =
  List.filter_map (fun id ->
    match Observation.observe_id (Identity_types.Cell_id.of_string id) with
    | Some h ->
        Some (id, Identity_types.Observed_hash.to_string h)
    | None -> None) cell_ids

(* --watch polling loop: run the program, snapshot observed cell hashes, poll
   for changes, re-run on change. Uses the pull scheduler in a loop — the
   persistent store's trace verification naturally skips unchanged nodes
   (hits) and recomputes changed ones (misses), so --watch and --once collapse
   to one store-level path. *)
let watch_loop session invocation ~files ~interval ~stabilize =
  let last_desired = ref None in
  let run_program () =
    (* Clear in-memory state for a fresh evaluation. The persistent store
       survives — this is the store-level collapse. run_files itself calls
       Repl.init () (via execute_sources / execute_file). *)
    Session.begin_pass session;
    (* Re-read and execute the program (plus, if --reconcile/--supervise is
       active, the domain-registration glue — run_files/uses_domains). *)
    let last = run_files invocation files in
    last_desired := last;
    run_domains_pass invocation last;
    (* Collect the cells we need to poll and snapshot their current hashes. *)
    let cell_ids = List.sort_uniq compare (List.map fst (Session.observations session)) in
    snapshot_cell_hashes cell_ids
  in
  let run_program_stabilize ~prev_snapshot changed_cells =
    let rev = Store_index.reverse () in
    let dirty = Store_index.dirty_keys changed_cells rev in
    Stabilize.reset_dirty (List.map Identity_types.Node_key.of_string dirty);
    Session.begin_pass session;
    let last = run_files ~retain_thunks:true invocation files in
    last_desired := last;
    run_domains_pass invocation last;
    let cell_ids = List.sort_uniq compare (List.map fst (Session.observations session)) in
    let new_obs = snapshot_cell_hashes cell_ids in
    let new_set = List.map fst new_obs in
    let prev_clean = List.filter (fun (id, _) -> not (List.mem id new_set)) prev_snapshot in
    new_obs @ prev_clean
  in
  (* First iteration: cold run. *)
  if stabilize then begin
    Session.begin_watch session
  end;
  let snapshot = run_program () in
  let rec loop snapshot =
    begin try Unix.sleepf interval
      with _ -> Unix.sleep 1 end;
    (* Clear run pins so observe_cell reads the current world, not the
       snapshot from the last run (CAS-ingest pins the first read of a cell
       for the rest of a run). *)
    Session.begin_pass session;
    (* Detect cell changes FIRST, before reconcile work, so config edits are
       noticed promptly. Then reconcile processes only when no cell changed —
       this still restarts killed services within one interval. *)
    let changed_cells =
      List.filter_map (fun (cell_id, recorded_hash) ->
        match Observation.observe_id (Identity_types.Cell_id.of_string cell_id) with
        | Some h when Identity_types.Observed_hash.to_string h <> recorded_hash ->
            Some cell_id
        | _ -> None) snapshot
    in
    if changed_cells <> [] then begin
      if stabilize then begin
        Printf.eprintf "[watch] %d cell(s) changed — stabilizing\n%!"
          (List.length changed_cells);
        let new_snapshot = run_program_stabilize ~prev_snapshot:snapshot changed_cells in
        loop new_snapshot
      end else begin
        Printf.eprintf "[watch] cell(s) changed — re-evaluating\n%!";
        let new_snapshot = run_program () in
        loop new_snapshot
      end
    end else begin
      (* Generalized from the old proc-only recheck: EVERY registered
         write-domain is re-observed/re-diffed/re-applied on every tick, not
         just proc — a killed service or an externally-drifted file is caught
         within one poll interval either way. Cheap when nothing actually
         changed: the plan cache (Domains.compute_plan) makes an unchanged
         pass a cache hit, not a re-walk. *)
      (match !last_desired with
       | Some v -> run_domains_pass invocation (Some v)
       | None -> ());
      loop snapshot
    end
  in
  loop snapshot

(* ---- Cluster transport / token CLI seam ----
   Each does its one internal job, given the args the flag table parsed; main
   dispatches to them so its body reads as a list of what pp can do rather than
   a wall of inline blocks. (The dispatcher, src/remote.ml, drives the token
   and transport machinery; these are the member-side entry points.) *)
let run_mint_token host ~(out : string) ~(ttl : int) ~(specs : string list) : unit =
  let secret = Cap_token.load_secret host in
  let cluster_id = Cap_token.load_cluster_id host in
  Store_layout.atomic_replace out (Cap_token.mint host ~secret ~cluster_id ~specs ~ttl_seconds:ttl)

let run_transport_push (kind, id, root) : unit =
  match kind with
  | "object" -> Transport.LocalDir.push_object root ~hash:id
  | "blob" -> Transport.LocalDir.push_blob root ~hash:id
  | "trace" -> Transport.LocalDir.push_trace root ~key:id
  | _ -> failwith ("pp --transport-push: unknown artifact kind " ^ kind)

let run_transport_pull (kind, id, root) : unit =
  match kind with
  | "object" -> Transport.LocalDir.pull_object root ~hash:id
  | "blob" -> Transport.LocalDir.pull_blob root ~hash:id
  | "trace" -> Transport.LocalDir.pull_trace root ~key:id
  | _ -> failwith ("pp --transport-pull: unknown artifact kind " ^ kind)

let run_serve_hit host session invocation (key, token_file, shared_root, reply_file) : unit =
  let token_text = read_file_content token_file in
  (* Cache_policy.lookup Cache_policy.default re-observes the trace's read cells, which performs the
     Lookup_handler/Record_read effects (observe_handler, file observation).
     serve-hit runs no program, so it must supply the same top-level
     observation context a plain run does: without it a node that read a
     handler/config cell can never re-observe (Lookup_handler is unhandled →
     stale → spurious miss), and a file re-observation crashes on an
     unhandled Record_read. with_top_level answers Lookup_handler with the
     builtin default the build itself recorded and makes Record_read a
     no-op, so a synced node verifies exactly as it does locally. *)
  let reply =
    Dynamic_scope.with_top_level session invocation
      ~f:(fun () -> Transport.serve_hit host ~key ~token_text ~shared_root) ()
  in
  Store_layout.atomic_replace reply_file reply

let run_recv_hit (reply_file, shared_root) : unit =
  let reply_text = read_file_content reply_file in
  match Transport.recv_hit ~reply_text ~shared_root with
  | Transport.RHit { key; result_hash; _ } ->
      Printf.printf "recv-hit: hit key=%s result=%s\n" key result_hash
  | Transport.RMiss key -> Printf.printf "recv-hit: miss key=%s\n" key
  | Transport.RDeny (key, reason) ->
      Printf.printf "recv-hit: deny key=%s reason=%s\n" key reason

let main () =
  let args = List.tl (Array.to_list Sys.argv) in
  let write_secret path content =
    let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
    let oc = Unix.out_channel_of_descr fd in
    output_string oc content;
    close_out oc
  in
  let read_secret path =
    let ic = open_in_bin path in
    let len = in_channel_length ic in
    let s = really_input_string ic len in
    close_in ic;
    let n = String.length s in
    if n > 0 && s.[n - 1] = '\n' then String.sub s 0 (n - 1) else s
  in
  let host = Host_services.make
      ~canonical_realpath:World_path.canonical_impl ~unix_time:Unix.time
      ~home_dir:(fun () -> Sys.getenv "HOME") ~read_secret ~write_secret
  in
  let eval_str = ref None in
  let files = ref [] in
  let grants = ref [] in
  let reconcile_root = ref None in
  let watch = ref false in
  let watch_interval = ref 1.0 in
  let graph_mode = ref false in
  let stabilize = ref false in
  let supervise = ref false in
  let fenced_policy = ref Invocation.Abort in
  let island_pins_file = ref None in
  (* Cluster transport/token CLI seam. *)
  let cluster_init_mode = ref false in
  let mint_token_args = ref None in    (* (out-file, ttl-seconds) *)
  let transport_push_args = ref None in (* (kind, hash-or-key, root) *)
  let transport_pull_args = ref None in (* (kind, hash-or-key, root) *)
  let serve_hit_args = ref None in     (* (key, token-file, shared-root, reply-file) *)
  let recv_hit_args = ref None in      (* (reply-file, shared-root) *)
  (* The cluster-member side of remote placement: internal — the
     dispatcher (src/remote.ml) invokes a member `pp` with this flag; not
     meant to be typed by hand. *)
  let remote_node_args = ref None in   (* (token-file, pins-file, shared-root, keys-file, reply-file) *)
  (* Host-qualified domain distribution + store GC. *)
  let member_name = ref None in            (* --member-name NAME: explicit opt-in host-keying *)
  let desired_object_args = ref None in    (* --desired-object HASH SHARED-ROOT (the by-hash pull seam) *)
  let publish_object_root = ref None in    (* --publish-object SHARED-ROOT (the by-hash publish seam) *)
  let gc_mark_out = ref None in            (* --gc-mark OUTFILE: internal, `pp gc`'s own replay subprocess *)
  let gc_mode = ref false in               (* `pp gc`: explicit, never automatic *)
  let gc_grace_seconds = ref Store_gc.default_grace_seconds in
  (* The observation-pinning seam — a standalone top-level generalization
     of --remote-node's pin machinery (which pre-seeds observation pins from
     the dispatcher's own granted fs-read scope before the disk is ever
     touched for a pinned cell), for pinning a DIFFERENT (adversarial)
     program's probe-in-desired-state reads, sans the token/keys/reply
     ceremony that flag also carries. *)
  let pin_file = ref None in               (* --pin-file PATH: preseed run_pins/probe_values before run_files *)
  let dump_pins_file = ref None in         (* --dump-pins PATH: write run_pins/probe_values after run_files *)
  (* The brace-surface CLI seams (SPEC Appendix B). `--emit-braces FILE`
     prints FILE's forms as location-preserving brace text;
     `--roundtrip-braces FILE` asserts sexpr-read -> brace-print ->
     brace-re-read gives structurally equal, LAW-20-hash-equal forms (the
     fuzzer's per-program gate, tools/fuzz.ml). *)
  let emit_braces_file = ref None in
  let roundtrip_braces_file = ref None in
  (* `pp fmt` — the lossless transpiler/formatter between the two reader
     surfaces (SPEC Appendix B). `--to-braces`/`--to-sexpr FILE [-i]`
     dispatch by FLAG, never by extension, so a file keeps its own name
     regardless of which surface it's written in.
     `--compare-hash`/`--list-comments` are internal seams for the fmt
     round-trip checks (per-form LAW-20 hash comparison across two files;
     dumping the comment side-channel for count/content checks) — not
     documented in --help, mirroring --emit-braces/--roundtrip-braces's own
     internal-tool tone. *)
  let fmt_args = ref None in           (* (`ToBraces|`ToSexpr, file, in_place) *)
  let compare_hash_args = ref None in  (* (file1, file2) *)
  let list_comments_args = ref None in (* (`Sexpr|`Brace, file) *)

  let program_argv = ref [] in
  let gc_keep_epochs = ref 5 in

  (* Arg-shape helpers: each returns the tokens it did not consume. A flag
     with too few args following it fails loudly rather than being silently
     re-read as a filename. *)
  let flag name f = { name; arity = 0; doc = ""; internal = true;
                      handler = (fun rest -> f (); rest) } in
  let opt1 name f = { name; arity = 1; doc = ""; internal = true;
                      handler = (function
                        | a :: rest -> f a; rest
                        | [] -> failwith (name ^ " requires one argument")) } in
  let doc_of d r = { r with doc = d; internal = false } in
  (* The remote-placement help line names the `remote:<member>` form
     literally, so the cluster placement surface stays greppable. *)
  let schedule_handler = function
    | spec :: rest ->
        (* Ambient — read only by the miss arms and Scheduler.dispatch_batch;
           NEVER by node_key_of, never in a trace (LAW 26/34). *)
        (match spec with
         | "serial" -> Scheduler.state.policy <- Scheduler.Serial
         | _ ->
             (match String.split_on_char ':' spec with
              | ["parallel"; n] ->
                  (match int_of_string_opt n with
                   | Some n when n > 0 -> Scheduler.state.policy <- Scheduler.Parallel n
                   | _ -> failwith ("invalid --schedule parallel width: " ^ n))
              | ["race"; n] ->
                  (match int_of_string_opt n with
                   | Some n when n > 0 -> Scheduler.state.policy <- Scheduler.Race n
                   | _ -> failwith ("invalid --schedule race width: " ^ n))
              | ["remote"; m] ->
                  if m = "" then failwith "invalid --schedule remote spec: empty member name"
                  else Scheduler.state.policy <- Scheduler.Remote m
              | _ -> failwith ("invalid --schedule spec: " ^ spec)));
        rest
    | [] -> failwith "--schedule requires a spec"
  in
  (* `fmt` owns the rest of argv itself (its own small flag set). *)
  let fmt_handler rest =
    let to_braces = ref None in
    let to_sexpr = ref None in
    let in_place = ref false in
    let rec parse_fmt = function
      | "--to-braces" :: f :: more -> to_braces := Some f; parse_fmt more
      | "--to-sexpr" :: f :: more -> to_sexpr := Some f; parse_fmt more
      | ("-i" | "--in-place") :: more -> in_place := true; parse_fmt more
      | [] -> ()
      | a :: _ -> failwith ("pp fmt: unrecognized argument: " ^ a)
    in
    parse_fmt rest;
    (match !to_braces, !to_sexpr with
     | Some f, None -> fmt_args := Some (`ToBraces, f, !in_place)
     | None, Some f -> fmt_args := Some (`ToSexpr, f, !in_place)
     | Some _, Some _ | None, None ->
         failwith "pp fmt: specify exactly one of --to-braces or --to-sexpr");
    []
  in
  let check_kernel_props_handler rest =
    (* Derived-generator kernel properties (hash injectivity, quote/printer
       round-trip), driven with a fixed seed for reproducibility. Optional:
       --seed N, --count K. *)
    let seed = ref 1 and count = ref 3000 in
    let rec grab = function
      | "--seed" :: n :: more -> seed := int_of_string n; grab more
      | "--count" :: k :: more -> count := int_of_string k; grab more
      | _ -> ()
    in
    grab rest;
    if Kernel_props.run ~seed:!seed ~count:!count then exit 0 else exit 1
  in

  let flags_ref : flag list ref = ref [] in
  let print_help () =
    Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\n";
    Printf.printf "Usage:\n";
    Printf.printf "  pp                       Start REPL\n";
    Printf.printf "  pp <file.pp>             Run a pp source file\n";
    List.iter (fun f -> if not f.internal then print_string f.doc) !flags_ref
  in

  let flags = [
    (* Everything after `--` is the program's argv (the `argv` builtin). *)
    { name = "--"; arity = -1; doc = ""; internal = true;
      handler = (fun rest -> program_argv := rest; []) };

    doc_of "  pp --update <file.pp>     Re-resolve islands and rewrite inline pins (implies --fetch-islands)\n"
      (flag "--update" (fun () ->
         Island.update_mode := true; Island.fetch_enabled := true));
    doc_of "  pp --fetch-islands        Allow git fetch for uncached island pins (default: off)\n"
      (flag "--fetch-islands" (fun () -> Island.fetch_enabled := true));

    doc_of "  pp --schedule serial|parallel:N|race:N|remote:MEMBER  Node-miss dispatch policy (default: serial); remote:<member> places misses on a cluster member (members: ~/.pp/cluster/members or $PP_CLUSTER_MEMBERS)\n"
      { name = "--schedule"; arity = 1; doc = ""; internal = false;
        handler = schedule_handler };

    doc_of "  pp island-pins <file.pp>  List island forms with pin and cache status\n"
      (opt1 "island-pins" (fun f -> island_pins_file := Some f));
    doc_of "  pp --grant <spec>        Grant capability (fs:/path:rw, net:host[:port], secret:/path, process)\n"
      (opt1 "--grant" (fun g -> grants := g :: !grants));

    (* ---- Cluster transport/token seam ----
       `cluster-init` mints ~/.pp/cluster/{secret,id}; the transport/token
       flags are internal test entries the exit tests drive directly. *)
    doc_of "  pp cluster-init          Mint ~/.pp/cluster/{secret,id} (the cluster trust anchor)\n"
      (flag "cluster-init" (fun () -> cluster_init_mode := true));
    doc_of "  pp --mint-token <out> <ttl-secs> [--grant ...]  Mint a signed cluster token\n"
      { name = "--mint-token"; arity = 2; doc = ""; internal = false;
        handler = (function
          | out :: ttl :: rest ->
              (match int_of_string_opt ttl with
               | Some t -> mint_token_args := Some (out, t)
               | None -> failwith ("invalid --mint-token ttl-seconds: " ^ ttl));
              rest
          | _ -> failwith "--mint-token requires <out> <ttl-seconds>") };
    doc_of "  pp --transport-push/--transport-pull object|blob|trace <id> <root>  Local-dir sync (internal)\n"
      { name = "--transport-push"; arity = 3; doc = ""; internal = false;
        handler = (function
          | kind :: id :: root :: rest -> transport_push_args := Some (kind, id, root); rest
          | _ -> failwith "--transport-push requires <kind> <id> <root>") };
    { name = "--transport-pull"; arity = 3; doc = ""; internal = true;
      handler = (function
        | kind :: id :: root :: rest -> transport_pull_args := Some (kind, id, root); rest
        | _ -> failwith "--transport-pull requires <kind> <id> <root>") };
    doc_of "  pp --serve-hit <key> <token-file> <shared-root> <reply-file>  Capability-gated hit (internal)\n"
      { name = "--serve-hit"; arity = 4; doc = ""; internal = false;
        handler = (function
          | key :: token_file :: shared_root :: reply_file :: rest ->
              serve_hit_args := Some (key, token_file, shared_root, reply_file); rest
          | _ -> failwith "--serve-hit requires <key> <token-file> <shared-root> <reply-file>") };
    doc_of "  pp --recv-hit <reply-file> <shared-root>  Ingest a serve-hit reply (internal)\n"
      { name = "--recv-hit"; arity = 2; doc = ""; internal = false;
        handler = (function
          | reply_file :: shared_root :: rest -> recv_hit_args := Some (reply_file, shared_root); rest
          | _ -> failwith "--recv-hit requires <reply-file> <shared-root>") };
    doc_of "  pp --remote-node <token> <pins> <root> <keys> <reply>  Cluster-member side of remote placement (internal)\n"
      { name = "--remote-node"; arity = 5; doc = ""; internal = false;
        handler = (function
          | token_file :: pins_file :: shared_root :: keys_file :: reply_file :: rest ->
              remote_node_args := Some (token_file, pins_file, shared_root, keys_file, reply_file); rest
          | _ -> failwith "--remote-node requires <token> <pins> <root> <keys> <reply>") };

    doc_of "  pp --reconcile <root>    Materialize the program's map value under <root>\n"
      (opt1 "--reconcile" (fun root -> reconcile_root := Some root));
    doc_of "  pp --supervise <file.pp>  Reconcile program's process-map value (use with --watch)\n"
      (flag "--supervise" (fun () -> supervise := true));

    (* ---- Host-qualified domain distribution + store GC ---- *)
    doc_of "  pp --member-name <n> [--reconcile/--supervise] <file>  Host-qualified domain distribution: converge only desired[<n>]'s slice\n"
      (opt1 "--member-name" (fun n -> member_name := Some n));
    doc_of "  pp --desired-object <hash> <shared-root> [--member-name <n>] [flags]  Pull a published desired-state value by hash and converge it (never runs a program to derive it)\n"
      { name = "--desired-object"; arity = 2; doc = ""; internal = false;
        handler = (function
          | hash :: root :: rest -> desired_object_args := Some (hash, root); rest
          | _ -> failwith "--desired-object requires <hash> <shared-root>") };
    doc_of "  pp --publish-object <shared-root> <file>  Publish the program's value (+ its blob: refs) to a shared local-dir store, by hash\n"
      (opt1 "--publish-object" (fun root -> publish_object_root := Some root));
    (* `--gc-mark` is internal: only `pp gc`'s own replay subprocess sets it. *)
    opt1 "--gc-mark" (fun out -> gc_mark_out := Some out);
    doc_of "  pp gc [--gc-keep-epochs N] [--gc-grace-seconds S]  Explicit store GC: mark-by-replay the last N reconcile/supervise epochs, sweep the rest\n"
      (flag "gc" (fun () -> gc_mode := true));
    opt1 "--gc-keep-epochs" (fun n ->
      match int_of_string_opt n with
      | Some k when k > 0 -> gc_keep_epochs := k
      | _ -> failwith ("invalid --gc-keep-epochs: " ^ n));
    opt1 "--gc-grace-seconds" (fun s ->
      match float_of_string_opt s with
      | Some g when g >= 0.0 -> gc_grace_seconds := g
      | _ -> failwith ("invalid --gc-grace-seconds: " ^ s));

    (* ---- The observation-pinning seam ---- *)
    doc_of "  pp --pin-file <path> <file.pp>  Preseed file and probe observations from a pin file before running\n"
      (opt1 "--pin-file" (fun path -> pin_file := Some path));
    doc_of "  pp --dump-pins <path> <file.pp>  After running, write every run_pins/probe_values entry as (pin ...)/(pin-probe ...) lines to <path>\n"
      (opt1 "--dump-pins" (fun path -> dump_pins_file := Some path));

    (* ---- Brace-surface seams ---- *)
    doc_of "  pp --emit-braces <file.ppl>  Print a sexpr (.ppl) file as brace-surface text (.pp/.ppb are brace surface, .ppl is the sexpr/AST surface)\n"
      (opt1 "--emit-braces" (fun f -> emit_braces_file := Some f));
    doc_of "  pp --roundtrip-braces <file.ppl>  Assert sexpr->braces->re-read AST + LAW-20 hash equality (the fuzz gate)\n"
      (opt1 "--roundtrip-braces" (fun f -> roundtrip_braces_file := Some f));

    (* ---- `pp fmt` seams ---- *)
    doc_of "  pp fmt --to-braces <file> [-i]  Transpile sexpr source to brace source, carrying comments (-i/--in-place rewrites the file, same path)\n  pp fmt --to-sexpr <file> [-i]   Transpile brace source to sexpr source, carrying comments\n"
      { name = "fmt"; arity = -1; doc = ""; internal = false; handler = fmt_handler };
    (* `--compare-hash` and `--list-comments` are internal fmt round-trip seams. *)
    { name = "--compare-hash"; arity = 2; doc = ""; internal = true;
      handler = (function
        | f1 :: f2 :: rest -> compare_hash_args := Some (f1, f2); rest
        | _ -> failwith "--compare-hash requires <file1> <file2>") };
    { name = "--list-comments"; arity = 2; doc = ""; internal = true;
      handler = (function
        | "sexpr" :: f :: rest -> list_comments_args := Some (`Sexpr, f); rest
        | "brace" :: f :: rest -> list_comments_args := Some (`Brace, f); rest
        | _ -> failwith "--list-comments requires sexpr|brace <file>") };

    doc_of "  pp --fenced-policy retry|abort|ask  Unknown-status fenced-action policy (default: abort)\n"
      (opt1 "--fenced-policy" (fun policy ->
         match policy with
         | "retry" -> fenced_policy := Invocation.Retry
         | "abort" -> fenced_policy := Invocation.Abort
         | "ask" -> fenced_policy := Invocation.Ask
         | _ -> failwith ("invalid --fenced-policy: " ^ policy)));

    doc_of "  pp why <file.pp>         Explain node cache hits/misses (capability-filtered)\n"
      (flag "why" (fun () -> Cache_policy.enable_why Cache_policy.default));
    { (flag "--why" (fun () -> Cache_policy.enable_why Cache_policy.default)) with internal = true };
    doc_of "  pp --no-cache <file.pp>  Skip cache reads (recompute); results still stored\n"
      (flag "--no-cache" (fun () -> Cache_policy.enable_no_cache Cache_policy.default));
    doc_of "  pp --check <file.pp>     Determinism audit: run each node twice, flag volatile\n"
      (flag "--check" (fun () -> Cache_policy.enable_check Cache_policy.default));
    doc_of "  pp -e '<expr>'           Evaluate an expression (brace syntax, like the REPL)\n"
      (opt1 "-e" (fun e -> eval_str := Some e));

    doc_of "  pp --version             Print version\n"
      (flag "--version" (fun () -> Printf.printf "pp v%s\n" Version.string; exit 0));
    { (flag "-v" (fun () -> Printf.printf "pp v%s\n" Version.string; exit 0)) with internal = true };
    (* Emit the surface tables as the SPEC-generated block; the copy committed
       to docs/SPEC.md is generated from here and must match it. Internal seam. *)
    flag "--dump-surface-tables"
      (fun () -> print_string (Surface_tables.render_spec_tables ()); exit 0);
    flag "--dump-builtins"
      (fun () -> print_string (Primitives.render_catalog ()); exit 0);
    { name = "--check-kernel-props"; arity = -1; doc = ""; internal = true;
      handler = check_kernel_props_handler };
    doc_of "  pp --help                Print this help\n"
      (flag "--help" (fun () -> print_help (); exit 0));
    { (flag "-h" (fun () -> print_help (); exit 0)) with internal = true };

    doc_of "  pp --once <file.pp>        Run once and exit (explicit; default behavior)\n"
      (flag "--once" (fun () -> ()));  (* no-op: explicit one-shot *)
    doc_of "  pp --watch <file.pp>       Run, then watch cell changes and re-evaluate\n  pp --watch --stabilize <file>  Watch with push stabilize (dirty-propagation)\n"
      (flag "--watch" (fun () -> watch := true));
    doc_of "  pp --watch-interval <s>   Poll interval for --watch (default 1.0)\n"
      (opt1 "--watch-interval" (fun secs -> watch_interval := float_of_string secs));
    (* --stabilize is documented alongside --watch above. *)
    flag "--stabilize" (fun () -> stabilize := true);
    doc_of "  pp graph                  Print the cell->node dependency graph from traces\n"
      (flag "graph" (fun () -> graph_mode := true));
    doc_of "  pp lint <file.pp>         Check source file for naming/style convention violations\n"
      (opt1 "lint" (fun f -> Lint.lint_file f));  (* Lint.lint_file exits *)
    doc_of "  pp run <file>            Run a pp source file\n"
      (opt1 "run" (fun f -> files := f :: !files));
  ] in
  flags_ref := flags;

  let rec parse = function
    | [] -> ()
    | tok :: rest ->
        (match List.find_opt (fun f -> f.name = tok) flags with
         | Some f -> parse (f.handler rest)
         | None ->
             (* Any unmatched token — a filename, or an unknown flag — is
                taken as a program file, exactly as before. *)
             files := tok :: !files; parse rest)
  in
  parse args;

  (* ---- Brace-surface seams — each does its one thing and exits.
     Both read the ORIGINAL (pre-macro-expansion) forms: surface identity is
     a reader-level property, and LAW 20 keys hash the located AST these
     produce. (read_whole is top-level.) *)
  (match !emit_braces_file with
   | Some f ->
       if Reader_braces.file_uses_braces f then
         failwith ("pp --emit-braces: " ^ f ^ " is already a brace file");
       let forms = Reader.read_string ~source:f (read_whole f) in
       (try print_string (Printer_braces.print_program ~source:f forms)
        with Printer_braces.Unprintable msg ->
          failwith ("pp --emit-braces: " ^ msg));
       exit 0
   | None -> ());
  (match !roundtrip_braces_file with
   | Some f ->
       if Reader_braces.file_uses_braces f then
         failwith ("pp --roundtrip-braces: " ^ f ^ " is already a brace file");
       let forms = Reader.read_string ~source:f (read_whole f) in
       let braces =
         try Printer_braces.print_program ~source:f forms
         with Printer_braces.Unprintable msg ->
           failwith ("roundtrip: unprintable: " ^ msg)
       in
       let forms' =
         try Reader_braces.read_string ~source:f braces
         with Failure msg ->
           Printf.eprintf "--- emitted brace text ---\n%s" braces;
           failwith ("roundtrip: brace re-read failed: " ^ msg)
       in
       if List.length forms <> List.length forms' then begin
         Printf.eprintf "--- emitted brace text ---\n%s" braces;
         failwith (Printf.sprintf
                     "roundtrip: form count diverged: %d sexpr vs %d brace"
                     (List.length forms) (List.length forms'))
       end;
       List.iteri (fun i (a, b) ->
         if a <> b then begin
           Printf.eprintf "--- emitted brace text ---\n%s" braces;
           failwith (Printf.sprintf "roundtrip: form %d is structurally unequal" i)
         end;
         let ha = Identity.hash_expr a and hb = Identity.hash_expr b in
         if ha <> hb then begin
           Printf.eprintf "--- emitted brace text ---\n%s" braces;
           failwith (Printf.sprintf
                       "roundtrip: form %d hash diverged: %s vs %s" i ha hb)
         end)
         (List.combine forms forms');
       exit 0
   | None -> ());

  (* `pp fmt` — read one surface, print the other, carrying comments
     via the Comments side channel (never touching the AST/eval path: the
     comment scanners run over the raw source text independently of
     whichever reader is invoked). *)
  (match !fmt_args with
   | Some (`ToBraces, f, in_place) ->
       let src = read_whole f in
       let forms = Reader.read_string ~source:f src in
       let comments = Comments.scan_sexpr src in
       (* comment lines are reserved: the pretty layout breaks around them
          so standalone comments splice back onto lines of their own *)
       let reserved = List.map (fun (c : Comments.t) -> c.line) comments in
       let base =
         try Printer_braces.print_program ~source:f ~reserved forms
         with Printer_braces.Unprintable msg ->
           failwith ("pp fmt --to-braces: " ^ msg)
       in
       let out = Comments.splice comments ~delim:'#' base in
       if in_place then begin
         let oc = open_out f in output_string oc out; close_out oc
       end else print_string out;
       exit 0
   | Some (`ToSexpr, f, in_place) ->
       let src = read_whole f in
       let forms = Reader_braces.read_string ~source:f src in
       let comments = Comments.scan_brace src in
       let base =
         try Printer_sexpr.print_program ~source:f forms
         with Printer_sexpr.Unprintable msg ->
           failwith ("pp fmt --to-sexpr: " ^ msg)
       in
       let out = Comments.splice comments ~delim:';' base in
       if in_place then begin
         let oc = open_out f in output_string oc out; close_out oc
       end else print_string out;
       exit 0
   | None -> ());
  (* Test seam: per-top-level-form LAW-20 hash comparison between two
     sexpr files, checking that a round-trip preserves every form's hash.
     Both are read
     with f1's path as the location label: LAW-20 hashes include the
     `ELocated` file name, and the round-trip contract this checks is
     specifically that transpiling IN PLACE (same
     path throughout, per `-i`'s contract) preserves every hash — a
     scratch second path is just where this test seam keeps the
     "before" copy, not a real distinct source location. *)
  (match !compare_hash_args with
   | Some (f1, f2) ->
       (* Each side dispatches by its OWN extension (a brace `.pp`
          can be compared against a sexpr `.ppl` scratch copy and vice
          versa); the location label stays f1 for both, per the round-trip
          contract described above. *)
       let forms1 =
         Reader_braces.read_dispatch ~source:f1 ~path:f1 (read_whole f1) in
       let forms2 =
         Reader_braces.read_dispatch ~source:f1 ~path:f2 (read_whole f2) in
       if List.length forms1 <> List.length forms2 then
         failwith (Printf.sprintf
                     "--compare-hash: form count diverged: %d (%s) vs %d (%s)"
                     (List.length forms1) f1 (List.length forms2) f2);
       List.iteri (fun i (a, b) ->
         let ha = Identity.hash_expr a and hb = Identity.hash_expr b in
         if ha <> hb then
           failwith (Printf.sprintf
                       "--compare-hash: form %d hash diverged: %s vs %s" i ha hb))
         (List.combine forms1 forms2);
       exit 0
   | None -> ());
  (* Test seam: dump the comment side channel (one "LINE: TEXT" line
     per comment, TEXT trimmed) so a shell test can diff count/content
     across a transpilation, independent of the `;`/`#` delimiter. *)
  (match !list_comments_args with
   | Some (surface, f) ->
       let src = read_whole f in
       let comments = match surface with
         | `Sexpr -> Comments.scan_sexpr src
         | `Brace -> Comments.scan_brace src
       in
       List.iter (fun (c : Comments.t) ->
         Printf.printf "%d: %s\n" c.line (String.trim c.text))
         comments;
       exit 0
   | None -> ());


  let source_roots =
    let raw_roots =
      Sys.getcwd ()
      :: List.map (fun f -> Filename.dirname f) !files
      @ (match World_path.stdlib_root () with Some d -> [d] | None -> [])
    in
    List.map World_path.canonical raw_roots
  in


  (* Parse --grant specs into capabilities (Capabilities.parse_grant lives
     in capabilities.ml, not a local closure here, so the signed-token
     verifier can reuse the exact same parser). Under
     --remote-node (the cluster-member side of remote placement), authority instead comes from a VERIFIED cluster token — never
     plain --grant strings — so a tampered/expired/wrong-secret token fails
     this member process outright (Failure -> the top-level handler ->
     exit 1), which the dispatcher (src/remote.ml) reads as "member
     failed" and degrades that batch to local compute. *)
  let initial_caps =
    match !remote_node_args with
    | Some (token_file, _, _, _, _) ->
        let token_text = Cell_repository.read_raw token_file in
        (match Cap_token.token_to_caps host token_text with
         | Ok caps -> caps
         | Error reason -> failwith ("pp: --remote-node: token rejected: " ^ reason))
    | None -> List.map (fun spec -> Capability.mint ~realpath:host.canonical_realpath spec) (List.rev !grants)
  in

  let invocation =
    match Invocation.create ~source_roots ~initial_capabilities:initial_caps ~command_argv:args
      ~program_argv:!program_argv ~program_files:(List.rev !files)
      ~initial_grant_specs:(List.rev !grants)
      ~program_reconcile_root:!reconcile_root ~program_supervise:!supervise
      ~program_member_name:!member_name ~program_desired_object:!desired_object_args
      ~gc_keep_epochs:!gc_keep_epochs ~fenced_policy:!fenced_policy with
    | Ok invocation -> invocation
    | Error msg -> failwith ("pp: " ^ msg)
  in
  let session = Session.create Evaluator.operations in
  (* Loader authority bound: the interpreter may load source from
     the CLI-named programs' directories, the cwd, and ~/.pp — nothing else.
     Also reachable: the resolved stdlib/ dir next to the
     running executable, so `--reconcile`/`--supervise`'s auto-loaded
     stdlib/domain-fs.pp / domain-proc.pp work from ANY cwd. *)
  Store_layout.init Store_layout.default;
  Remote.init host invocation;
  (* `--gc-mark` (internal — only `pp gc`'s own replay
     subprocess, src/store_gc.ml, sets this) turns on cache policy's
     mark-by-replay side channel for the whole remainder of this process. *)
  (match !gc_mark_out with Some _ -> Cache_policy.begin_gc Cache_policy.default | None -> ());
  (* The by-hash desired-value pull seam — given a hash
     already published (via `--publish-object`) into a shared local-dir
     root, pull the object AND every "blob:" ref it names (Blobref.blob_refs_in,
     shared with src/remote.ml's identical need) before anything else runs.
     Every pull re-hash-verifies before accepting (Transport.LocalDir.pull_*
     -> ingest_object/ingest_blob), the same choke point every other synced
     artifact goes through — re-hash-on-receive, same as every other synced
     artifact. Does NOT sync fenced actions or
     journals: only the value object and its blob: refs
     ever cross here. *)
  (match !desired_object_args with
   | Some (hash, root) ->
       Transport.LocalDir.pull_object root ~hash;
       (match Object_repository.get Object_repository.default ~key:hash with
        | Some v ->
            List.iter (fun h -> try Transport.LocalDir.pull_blob root ~hash:h with _ -> ())
              (Blobref.blob_refs_in v)
        | None -> ())
   | None -> ());
  (* Pre-seed observation pins from the dispatcher's
     wire BEFORE run_files ever executes a single expression — this member
     process must never observe its own disk for a pre-seeded cell, and
     the only way to make that structural (not just conventional) is to
     populate the pin before the FIRST observation can happen at all. *)
  (match !remote_node_args with
   | Some (_, pins_file, _, _, _) ->
       Remote.preseed_pins_from_file session ~pins_file
   | None -> ());
  (* `--pin-file <path>` — the SAME preseed logic, standalone,
     no --remote-node ceremony. Also runs before run_files ever executes anything, for the
     same structural reason as above. Composes with --remote-node
     harmlessly (both would just preseed from their own file; not a
     supported/needed combination in practice, but neither excludes the
     other). *)
  (match !pin_file with
   | Some path -> Remote.preseed_pins_from_file session ~pins_file:path
   | None -> ());
  (* Collect every cell observation made by the program: needed for
     stratification (LAW 30) and for --watch polling. Unconditional (not
     gated on --reconcile/--watch/--supervise): a program may call
     register-domain itself with neither flag set — main.ml cannot know in
     advance whether the program it is about to run will do that, so
     collection must always be live for the stratification check
     domains.ml performs after root evaluation to see anything at all.
     The cost is one list-cons per cell read; unused when nothing
     converges. *)
  (* Recover any unknown-status fenced actions from a prior crash before
     applying new state (LAW 31). Skipped under `--gc-mark`: a GC
     replay must never perform a real recovery action — see the --gc-mark
     branch below, which also skips run_domains_pass/Fenced.drain for the
     same reason (mark-by-replay is read-only on the world by construction,
     not merely by convention). *)
  if (!reconcile_root <> None || !supervise) && !gc_mark_out = None then
    Dynamic_scope.with_top_level session invocation
      ~f:(fun () -> Fenced.recover_unknown ~policy:!fenced_policy) ();


  (* pp graph: just scan and print, no file needed. *)
  if !graph_mode then (print_graph (); exit 0);
  (* ---- Cluster transport/token CLI seam ----
     Administrative/test entries: each does its one thing and exits.
     Errors (bad token, corrupt/tampered artifact, missing secret) propagate
     as Failure/Transport.Transport_integrity_error to the top-level handler
     below, printed uniformly as "pp: error: ...". *)
  if !cluster_init_mode then begin
    Store_layout.ensure_dir (Cap_token.cluster_dir host);
    if Sys.file_exists (Cap_token.secret_path host) then
      failwith (Printf.sprintf
        "pp cluster-init: a cluster secret already exists at %s — refusing \
         to overwrite (this would invalidate every token already minted \
         against it); remove it by hand first if you really mean to rotate"
        (Cap_token.secret_path host));
    let secret_hex = Hasher.hex_encode (Cryptokit.Random.string Cryptokit.Random.secure_rng 32) in
    Cap_token.write_secret_file host (Cap_token.secret_path host) (secret_hex ^ "\n");
    let cluster_id = Hasher.hex_encode (Cryptokit.Random.string Cryptokit.Random.secure_rng 16) in
    if not (Sys.file_exists (Cap_token.id_path host)) then
      Store_layout.atomic_replace (Cap_token.id_path host) (cluster_id ^ "\n");
    Printf.printf
      "pp cluster-init: minted %s (mode 0600) and cluster id %s\n\
       pp cluster-init: distribute BOTH files to other cluster members out \
       of band, at the same path (~/.pp/cluster/) — pp never transmits them\n"
      (Cap_token.secret_path host) cluster_id;
    exit 0
  end;
  (match !mint_token_args with
   | Some (out, ttl) -> run_mint_token host ~out ~ttl ~specs:(List.rev !grants); exit 0
   | None -> ());
  (match !transport_push_args with
   | Some a -> run_transport_push a; exit 0 | None -> ());
  (match !transport_pull_args with
   | Some a -> run_transport_pull a; exit 0 | None -> ());
  (match !serve_hit_args with
   | Some a -> run_serve_hit host session invocation a; exit 0 | None -> ());
  (match !recv_hit_args with
   | Some a -> run_recv_hit a; exit 0 | None -> ());
  (* ---- `pp gc` (explicit, never automatic) ---- *)
  if !gc_mode then
    (Dynamic_scope.with_top_level session invocation
       ~f:(fun () -> Store_gc.run ~grace_seconds:!gc_grace_seconds) ();
     exit 0);
  (* ---- `--publish-object <shared-root>` — the by-hash
     desired-value PUBLISH seam's dispatcher side: run the program
     normally, store its (fully-forced) value as an ordinary content-
     addressed object, push it AND every "blob:" ref it names (Blobref
     .blob_refs_in — shared with src/remote.ml's identical need) into
     [shared_root], and print the hash a member consumes via
     `--desired-object <hash> <shared-root>`. Deliberately does NOT run
     run_domains_pass here — publishing is the DISPATCHER computing a value
     to hand off, not converging anything itself. Never pushes fenced
     actions or journals (nothing here ever touches either). *)
  (match !publish_object_root with
   | Some shared_root ->
       Dynamic_scope.with_top_level session invocation ~f:(fun () ->
         match run_files invocation (List.rev !files) with
         | None -> failwith "pp: --publish-object: the program produced no value"
         | Some v ->
             let forced = Force_deep.force_deep v in
             let hash = Identity.hash_value forced in
             (match Codec.encode_value forced with
              | None ->
                  failwith "pp: --publish-object: the program's value contains \
                            code (a closure/thunk/handle) and cannot be \
                            published as data"
              | Some _ -> Object_repository.put Object_repository.default ~key:hash ~value:forced);
             List.iter (fun h -> try Transport.LocalDir.push_blob shared_root ~hash:h with _ -> ())
               (Blobref.blob_refs_in forced);
             Transport.LocalDir.push_object shared_root ~hash;
             Printf.printf "publish-object: %s\n" hash) ();
       exit 0
   | None -> ());
  (* ---- `--gc-mark <outfile>` — internal, only `pp gc`'s own
     replay subprocess (src/store_gc.ml) sets this. Runs the recorded root
     program EXACTLY as a live pass would (registration glue, the user's
     file(s), the same --grant/--reconcile/--supervise/
     marks its trace/object/blob(s) live (Cache_policy.begin_gc, turned on
     earlier, right after Store_layout.init) — then STOPS: no run_domains_pass (no
     domain apply), no Fenced.recover_unknown/drain (already skipped
     above). This is what makes replay read-only on the world by
     construction: nothing below this branch ever runs. *)
  (match !gc_mark_out with
   | Some out ->
       let last = Dynamic_scope.with_top_level session invocation
           ~f:(fun () -> run_files invocation (List.rev !files)) () in
       (try
          let all = select_member_slice invocation (compute_all_desired invocation last) in
          let forced = Force_deep.force_deep all in
          Cache_policy.mark Cache_policy.default ("object:" ^ Identity.hash_value forced);
          List.iter (fun h -> Cache_policy.mark Cache_policy.default ("blob:" ^ h)) (Blobref.blob_refs_in forced)
        with _ ->
          (* A root whose desired-state can no longer be derived at all
             (e.g. should_run_domains () is false for this replay) still
             marks whatever Cache_policy.lookup Cache_policy.default calls run_files itself made above —
             conservative, not a hard failure of the whole replay. *)
          ());
       let marks = Hashtbl.fold (fun k () acc -> k :: acc)
           (Cache_policy.gc_marks Cache_policy.default) [] in
       Store_layout.atomic_replace out (String.concat "\n" marks ^ (if marks = [] then "" else "\n"));
       exit 0
   | None -> ());
  (* pp island-pins <file>: list island forms with pin + cache status. *)
  (match !island_pins_file with
   | Some f -> Island.print_pins f; exit 0
   | None -> ());
  (* --update: rewrite inline island pins in each named file, then run. *)
  if !Island.update_mode then
    List.iter (fun f ->
      let updated, skipped = Island.update_file f in
      if updated > 0 || skipped > 0 then
        Printf.eprintf "[update] %s: %d pin(s) updated, %d skipped\n%!"
          f updated skipped)
      (List.rev !files);
  begin
    let _ = Dynamic_scope.with_top_level session invocation ~f:(fun () ->
      (match !eval_str, !files with
      | Some e, [] ->
          let results = Repl.execute_string e in
          List.iter (fun v ->
            Printf.printf "%s\n" (Presentation.string_of_value v)
          ) results
      | None, [] -> Repl.repl ()
      | _, files ->
          let files = List.rev files in
          if !watch then
            watch_loop session invocation ~files ~interval:!watch_interval ~stabilize:!stabilize
          else begin
            let last = run_files invocation files in
            run_domains_pass invocation last;
            (match !dump_pins_file with
             | Some path ->
                 let buf = Buffer.create 256 in
                 Session.iter_run_pins session (fun cell hash ->
                   Buffer.add_string buf (Remote.pin_line cell hash));
                 Session.iter_probes session (fun name v ->
                   match Codec.encode_value v with
                   | Some text -> Buffer.add_string buf (Remote.pin_probe_line name text)
                   | None ->
                       Printf.eprintf
                         "[dump-pins] skipping non-data probe value for %s (code/handle/sealed)\n%!"
                         name);
                 Store_layout.atomic_replace path (Buffer.contents buf)
             | None -> ());
            if Cache_policy.check_enabled Cache_policy.default && Scheduler.state.policy <> Scheduler.Serial then
              (match last with
               | None -> ()
               | Some v ->
                   let h_scheduled = Identity.hash_value v in
                   let saved_policy = Scheduler.state.policy in
                   let policy_name = function
                     | Scheduler.Serial -> "serial"
                     | Scheduler.Parallel n -> Printf.sprintf "parallel:%d" n
                     | Scheduler.Race n -> Printf.sprintf "race:%d" n
                     | Scheduler.Remote m -> Printf.sprintf "remote:%s" m
                   in
                   Scheduler.state.policy <- Scheduler.Serial;
                   Session.begin_pass session;
                   let last_serial = run_files invocation files in
                   Scheduler.state.policy <- saved_policy;
                   (match last_serial with
                    | None -> ()
                    | Some v2 ->
                        if Identity.hash_value v2 <> h_scheduled then begin
                          Cache_policy.note_volatile Cache_policy.default;
                          Printf.eprintf
                            "[check] schedule non-transparent: %s and serial re-runs produced different desired-state hashes\n%!"
                            (policy_name saved_policy)
                        end))
          end)
    ) ()
    in ()
  end;
  (* After running the program (whatever nodes that forced,
     including — but not limited to — the dispatcher's assigned batch keys;
     duplicate/extra computation here is sound), serve each assigned key back to the
     dispatcher via Transport.serve_hit, once per key,
     against THIS process's own now-populated store. *)
  (match !remote_node_args with
   | Some (token_file, _, shared_root, keys_file, reply_file) ->
       let token_text = Cell_repository.read_raw token_file in
       (* Cache_policy.lookup Cache_policy.default replays a verified trace's reads via Observation.replay,
          which performs Record_read/Get_observe_all — so this after-run serve
          must hold the same top-level observation context the run itself held
          (line 1050), or a clean hit crashes on an unhandled effect. *)
       Dynamic_scope.with_top_level session invocation
         ~f:(fun () ->
           Remote.serve_assigned_keys host ~token_text ~keys_file ~shared_root
             ~reply_file) ()
   | None -> ());

  (* --check verdict: any volatile node fails the audit (LAW 38). *)
  if Cache_policy.check_enabled Cache_policy.default && Cache_policy.volatile_count Cache_policy.default > 0 then begin
    Printf.eprintf "[check] FAIL: %d volatile node(s) flagged\n%!"
      (Cache_policy.volatile_count Cache_policy.default);
    exit 1
  end

(* Uncaught runtime errors print as one clean line, not an OCaml backtrace
   header. Exit 1. *)
let () =
  try main () with
  | Source_error.Pp_exit n -> exit n
  (* Pp_error's registered printer renders "<msg> at file:line". The rest are
     unlocated leaf errors that never crossed a form boundary (CLI validation,
     transport, an unlocated reader failwith). *)
  | Source_error.Pp_error _ as e ->
      Printf.eprintf "pp: error: %s\n%!" (Printexc.to_string e);
      exit 1
  | Failure msg | Source_error.Capability_error msg | Sys_error msg
  | Transport.Transport_integrity_error msg ->
      Printf.eprintf "pp: error: %s\n%!" msg;
      exit 1
