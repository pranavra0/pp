(* pp main — entry point for the pp interpreter *)

let main () =
  let args = List.tl (Array.to_list Sys.argv) in
  let bytecode = ref false in
  let diff = ref false in
  let eval_str = ref None in
  let files = ref [] in
  let grants = ref [] in
  let reconcile_root = ref None in
  let watch = ref false in
  let watch_interval = ref 1.0 in
  let graph_mode = ref false in
  let stabilize = ref false in
  let supervise = ref false in
  let fenced_policy = ref Runtime.Abort in
  let island_pins_file = ref None in
  (* M5 stage A: cluster transport/token CLI seam (docs/PLAN-m5-distribution.md). *)
  let cluster_init_mode = ref false in
  let mint_token_args = ref None in    (* (out-file, ttl-seconds) *)
  let transport_push_args = ref None in (* (kind, hash-or-key, root) *)
  let transport_pull_args = ref None in (* (kind, hash-or-key, root) *)
  let serve_hit_args = ref None in     (* (key, token-file, shared-root, reply-file) *)
  let recv_hit_args = ref None in      (* (reply-file, shared-root) *)
  (* M5 stage B: the cluster-member side of remote placement
     (docs/PLAN-m5-distribution.md "Remote placement" / "Q11-bis").
     Internal — the dispatcher (src/remote.ml) invokes a member `pp` with
     this flag; not meant to be typed by hand. *)
  let remote_node_args = ref None in   (* (token-file, pins-file, shared-root, keys-file, reply-file) *)
  (* M5 stage C: host-qualified domain distribution + store GC
     (docs/PLAN-m5-distribution.md "Host-qualified domain distribution" /
     "Store GC"). *)
  let member_name = ref None in            (* --member-name NAME: explicit opt-in host-keying *)
  let desired_object_args = ref None in    (* --desired-object HASH SHARED-ROOT (the by-hash pull seam) *)
  let publish_object_root = ref None in    (* --publish-object SHARED-ROOT (the by-hash publish seam) *)
  let gc_mark_out = ref None in            (* --gc-mark OUTFILE: internal, `pp gc`'s own replay subprocess *)
  let gc_mode = ref false in               (* `pp gc`: explicit, never automatic *)
  let gc_grace_seconds = ref Store_gc.default_grace_seconds in
  (* M6 stage B: the observation-pinning seam (docs/PLAN-m6-demo.md
     "Stage B — the pin seam") — a standalone top-level generalization of
     Q11-bis's --remote-node pin machinery, for pinning a DIFFERENT
     (adversarial) program's probe-in-desired-state reads, sans the
     token/keys/reply ceremony that flag also carries. *)
  let pin_file = ref None in               (* --pin-file PATH: preseed run_pins/probe_values before run_files *)
  let dump_pins_file = ref None in         (* --dump-pins PATH: write run_pins/probe_values after run_files *)

  let rec parse = function
    | "--" :: rest ->
        (* Everything after `--` is the program's argv (the `argv` builtin). *)
        Runtime.program_argv := rest
    | "--bytecode" :: rest -> bytecode := true; parse rest
    | "--diff" :: rest -> diff := true; bytecode := true; parse rest
    | "--update" :: rest ->
        (* Re-resolve island refs and rewrite inline pins (implies fetch). *)
        Island.update_mode := true;
        Runtime.island_fetch_enabled := true;
        parse rest
    | "--fetch-islands" :: rest -> Runtime.island_fetch_enabled := true; parse rest
    | "--schedule" :: spec :: rest ->
        (* Ambient — read only by the miss arms and Scheduler.dispatch_batch;
           NEVER by node_key_of/vm_node_key, never in a trace (LAW 26/34). *)
        (match spec with
         | "serial" -> Scheduler.policy := Scheduler.Serial
         | _ ->
             (match String.split_on_char ':' spec with
              | ["parallel"; n] ->
                  (match int_of_string_opt n with
                   | Some n when n > 0 -> Scheduler.policy := Scheduler.Parallel n
                   | _ -> failwith ("invalid --schedule parallel width: " ^ n))
              | ["race"; n] ->
                  (match int_of_string_opt n with
                   | Some n when n > 0 -> Scheduler.policy := Scheduler.Race n
                   | _ -> failwith ("invalid --schedule race width: " ^ n))
              | ["remote"; m] ->
                  if m = "" then failwith "invalid --schedule remote spec: empty member name"
                  else Scheduler.policy := Scheduler.Remote m
              | _ -> failwith ("invalid --schedule spec: " ^ spec)));
        parse rest
    | "island-pins" :: f :: rest -> island_pins_file := Some f; parse rest
    | "--grant" :: grant :: rest -> grants := grant :: !grants; parse rest
    (* ---- M5 stage A: cluster transport/token CLI seam ----
       `cluster-init` mints ~/.pp/cluster/{secret,id}; the rest are
       internal test entries the exit tests drive directly (a real ssh
       transport, stage B, will get an ambient membership-driven CLI —
       these flags are deliberately low-level and explicit). *)
    | "cluster-init" :: rest -> cluster_init_mode := true; parse rest
    | "--mint-token" :: out :: ttl :: rest ->
        (match int_of_string_opt ttl with
         | Some t -> mint_token_args := Some (out, t)
         | None -> failwith ("invalid --mint-token ttl-seconds: " ^ ttl));
        parse rest
    | "--transport-push" :: kind :: id :: root :: rest ->
        transport_push_args := Some (kind, id, root); parse rest
    | "--transport-pull" :: kind :: id :: root :: rest ->
        transport_pull_args := Some (kind, id, root); parse rest
    | "--serve-hit" :: key :: token_file :: shared_root :: reply_file :: rest ->
        serve_hit_args := Some (key, token_file, shared_root, reply_file); parse rest
    | "--recv-hit" :: reply_file :: shared_root :: rest ->
        recv_hit_args := Some (reply_file, shared_root); parse rest
    | "--remote-node" :: token_file :: pins_file :: shared_root :: keys_file :: reply_file :: rest ->
        remote_node_args := Some (token_file, pins_file, shared_root, keys_file, reply_file);
        parse rest
    | "--reconcile" :: root :: rest -> reconcile_root := Some root; parse rest
    | "--supervise" :: rest -> supervise := true; parse rest
    (* ---- M5 stage C: host-qualified domain distribution + store GC ---- *)
    | "--member-name" :: n :: rest -> member_name := Some n; parse rest
    | "--desired-object" :: hash :: root :: rest ->
        desired_object_args := Some (hash, root); parse rest
    | "--publish-object" :: root :: rest -> publish_object_root := Some root; parse rest
    | "--gc-mark" :: out :: rest -> gc_mark_out := Some out; parse rest
    | "--gc-keep-epochs" :: n :: rest ->
        (match int_of_string_opt n with
         | Some k when k > 0 -> Runtime.gc_keep_epochs := k
         | _ -> failwith ("invalid --gc-keep-epochs: " ^ n));
        parse rest
    | "--gc-grace-seconds" :: s :: rest ->
        (match float_of_string_opt s with
         | Some g when g >= 0.0 -> gc_grace_seconds := g
         | _ -> failwith ("invalid --gc-grace-seconds: " ^ s));
        parse rest
    | "gc" :: rest -> gc_mode := true; parse rest
    (* ---- M6 stage B: the pin seam ---- *)
    | "--pin-file" :: path :: rest -> pin_file := Some path; parse rest
    | "--dump-pins" :: path :: rest -> dump_pins_file := Some path; parse rest
    | "--fenced-policy" :: policy :: rest ->
        (match policy with
         | "retry" -> fenced_policy := Runtime.Retry
         | "abort" -> fenced_policy := Runtime.Abort
         | "ask" -> fenced_policy := Runtime.Ask
         | _ -> failwith ("invalid --fenced-policy: " ^ policy));
        parse rest
    | "why" :: rest | "--why" :: rest -> Store.why_mode := true; parse rest
    | "--no-cache" :: rest -> Store.no_cache := true; parse rest
    | "--check" :: rest -> Store.check_mode := true; parse rest
    | "-e" :: e :: rest -> eval_str := Some e; parse rest
    | "--version" :: _ | "-v" :: _ ->
        Printf.printf "pp v%s\n" Version.string; exit 0
    | "--help" :: _ | "-h" :: _ ->
        Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\n";
        Printf.printf "Usage:\n";
        Printf.printf "  pp                       Start REPL\n";
        Printf.printf "  pp <file.pp>             Run a pp source file\n";
        Printf.printf "  pp --bytecode <file.pp>  Run via bytecode VM\n";
        Printf.printf "  pp --diff <file.pp>      Run both backends and diff\n";
        Printf.printf "  pp -e '<expr>'           Evaluate an expression\n";
        Printf.printf "  pp --grant <spec>        Grant capability (fs:/path:rw, net:host[:port], secret:/path, process)\n";
        Printf.printf "  pp --reconcile <root>    Materialize the program's map value under <root>\n";
        Printf.printf "  pp --supervise <file.pp>  Reconcile program's process-map value (use with --watch)\n";
        Printf.printf "  pp --fenced-policy retry|abort|ask  Unknown-status fenced-action policy (default: abort)\n";
        Printf.printf "  pp why <file.pp>         Explain node cache hits/misses (capability-filtered)\n";
        Printf.printf "  pp --no-cache <file.pp>  Skip cache reads (recompute); results still stored\n";
        Printf.printf "  pp --check <file.pp>     Determinism audit: run each node twice, flag volatile\n";
        Printf.printf "  pp --schedule serial|parallel:N|race:N|remote:MEMBER  Node-miss dispatch policy (default: serial)\n";
        Printf.printf "  pp --once <file.pp>        Run once and exit (explicit; default behavior)\n";
        Printf.printf "  pp --watch <file.pp>       Run, then watch cell changes and re-evaluate\n";
        Printf.printf "  pp --watch --stabilize <file>  Watch with push stabilize (dirty-propagation)\n";
        Printf.printf "  pp graph                  Print the cell->node dependency graph from traces\n";
        Printf.printf "  pp island-pins <file.pp>  List island forms with pin and cache status\n";
        Printf.printf "  pp --update <file.pp>     Re-resolve islands and rewrite inline pins (implies --fetch-islands)\n";
        Printf.printf "  pp --fetch-islands        Allow git fetch for uncached island pins (default: off)\n";
        Printf.printf "  pp --watch-interval <s>   Poll interval for --watch (default 1.0)\n";
        Printf.printf "  pp run <file>            Run a pp source file\n";
        Printf.printf "  pp --version             Print version\n";
        Printf.printf "  pp --help                Print this help\n";
        Printf.printf "  pp cluster-init          Mint ~/.pp/cluster/{secret,id} (M5 cluster trust anchor)\n";
        Printf.printf "  pp --mint-token <out> <ttl-secs> [--grant ...]  Mint a signed cluster token\n";
        Printf.printf "  pp --transport-push/--transport-pull object|blob|trace <id> <root>  Local-dir sync (internal)\n";
        Printf.printf "  pp --serve-hit <key> <token-file> <shared-root> <reply-file>  Capability-gated hit (internal)\n";
        Printf.printf "  pp --recv-hit <reply-file> <shared-root>  Ingest a serve-hit reply (internal)\n";
        Printf.printf "  pp --schedule remote:<member>  Remote placement (M5 stage B); members: ~/.pp/cluster/members or $PP_CLUSTER_MEMBERS\n";
        Printf.printf "  pp --remote-node <token> <pins> <root> <keys> <reply>  Cluster-member side of remote placement (internal)\n";
        Printf.printf "  pp --member-name <n> [--reconcile/--supervise] <file>  Host-qualified domain distribution (M5 stage C): converge only desired[<n>]'s slice\n";
        Printf.printf "  pp --publish-object <shared-root> <file>  Publish the program's value (+ its blob: refs) to a shared local-dir store, by hash\n";
        Printf.printf "  pp --desired-object <hash> <shared-root> [--member-name <n>] [flags]  Pull a published desired-state value by hash and converge it (never runs a program to derive it)\n";
        Printf.printf "  pp gc [--gc-keep-epochs N] [--gc-grace-seconds S]  Explicit store GC (M5 stage C): mark-by-replay the last N reconcile/supervise epochs, sweep the rest\n";
        Printf.printf "  pp --pin-file <path> <file.pp>  Preseed Store.run_pins/Runtime.probe_values from a (pin ...)/(pin-probe ...) file before running (M6 stage B: the observation-pinning seam)\n";
        Printf.printf "  pp --dump-pins <path> <file.pp>  After running, write every run_pins/probe_values entry as (pin ...)/(pin-probe ...) lines to <path>\n";
        exit 0
    | "--once" :: rest -> parse rest  (* no-op: explicit one-shot *)
    | "--watch" :: rest -> watch := true; parse rest
    | "--watch-interval" :: secs :: rest ->
        watch_interval := float_of_string secs; parse rest
    | "--stabilize" :: rest -> stabilize := true; parse rest
    | "graph" :: rest -> graph_mode := true; parse rest
    | "run" :: f :: rest -> files := f :: !files; parse rest
    | f :: rest -> files := f :: !files; parse rest
    | [] -> ()
  in
  parse args;

  (* M5 stage B (docs/PLAN-m5-distribution.md "Remote placement"): record
     this invocation's own file list / --bytecode / raw --grant specs so
     src/remote.ml can replicate them when spawning a cluster member as an
     ordinary second `pp` invocation of the identical program. *)
  Runtime.program_files := List.rev !files;
  Runtime.program_bytecode := !bytecode;
  Runtime.initial_grant_specs := List.rev !grants;
  (* M5 stage C: the additional CLI shape this invocation was given, for the
     SAME reason — Gcroots.record (domains.ml) needs it to reconstruct an
     identical `pp` invocation later, for `pp gc`'s mark-by-replay. *)
  Runtime.program_reconcile_root := !reconcile_root;
  Runtime.program_supervise := !supervise;
  Runtime.program_member_name := !member_name;
  Runtime.program_desired_object := !desired_object_args;

  (* Parse --grant specs into capabilities (Capabilities.parse_grant — M5
     moved this out of a local closure here so the signed-token verifier
     can reuse the exact same parser; see capabilities.ml). Under
     --remote-node (the cluster-member side of remote placement, M5 stage
     B), authority instead comes from a VERIFIED cluster token — never
     plain --grant strings — so a tampered/expired/wrong-secret token fails
     this member process outright (Failure -> the top-level handler ->
     exit 1), which the dispatcher (src/remote.ml) reads as "member
     failed" and degrades that batch to local compute. *)
  let initial_caps =
    match !remote_node_args with
    | Some (token_file, _, _, _, _) ->
        let token_text = Store.read_raw token_file in
        (match Token.token_to_caps token_text with
         | Ok caps -> caps
         | Error reason -> failwith ("pp: --remote-node: token rejected: " ^ reason))
    | None -> List.map Capabilities.parse_grant (List.rev !grants)
  in
  Runtime.initial_capabilities := initial_caps;
  (* Loader authority bound (Q6/D8c): the interpreter may load source from
     the CLI-named programs' directories, the cwd, and ~/.pp — nothing else.
     Q13 loader reachability: also the resolved stdlib/ dir next to the
     running executable, so `--reconcile`/`--supervise`'s auto-loaded
     stdlib/domain-fs.pp / domain-proc.pp work from ANY cwd. *)
  Runtime.source_roots :=
    Runtime.canonical_path (Sys.getcwd ())
    :: List.map (fun f -> Filename.dirname (Runtime.canonical_path f)) !files
    @ (match Runtime.stdlib_root () with Some d -> [d] | None -> []);
  Store.init ();
  Remote.init ();
  (* M5 stage C: `--gc-mark` (internal — only `pp gc`'s own replay
     subprocess, src/store_gc.ml, sets this) turns on Store.hit's
     mark-by-replay side channel for the whole remainder of this process. *)
  (match !gc_mark_out with Some _ -> Store.gc_marking := true | None -> ());
  (* M5 stage C: the by-hash desired-value pull seam (docs/PLAN-m5-
     distribution.md "Host-qualified domain distribution") — given a hash
     already published (via `--publish-object`) into a shared local-dir
     root, pull the object AND every "blob:" ref it names (Blobref.blob_refs_in,
     shared with src/remote.ml's identical need) before anything else runs.
     Every pull re-hash-verifies before accepting (Transport.LocalDir.pull_*
     -> ingest_object/ingest_blob), the same choke point every other synced
     artifact goes through — T1 unchanged. Does NOT sync fenced actions or
     journals (per the contract): only the value object and its blob: refs
     ever cross here. *)
  (match !desired_object_args with
   | Some (hash, root) ->
       Transport.LocalDir.pull_object root ~hash;
       (match Store.load_object ~key:hash with
        | Some v ->
            List.iter (fun h -> try Transport.LocalDir.pull_blob root ~hash:h with _ -> ())
              (Blobref.blob_refs_in v)
        | None -> ())
   | None -> ());
  (* M5 stage B / Q11-bis: pre-seed Store.run_pins from the dispatcher's
     wire BEFORE run_files ever executes a single expression — this member
     process must never observe its own disk for a pre-seeded cell, and
     the only way to make that structural (not just conventional) is to
     populate the pin before the FIRST observation can happen at all. *)
  (match !remote_node_args with
   | Some (_, pins_file, _, _, _) ->
       Remote.preseed_pins_from_file ~pins_file
   | None -> ());
  (* M6 stage B: `--pin-file <path>` — the SAME preseed logic, standalone,
     no --remote-node ceremony (docs/PLAN-m6-demo.md "Stage B — the pin
     seam"). Also runs before run_files ever executes anything, for the
     same structural reason as above. Composes with --remote-node
     harmlessly (both would just preseed from their own file; not a
     supported/needed combination in practice, but neither excludes the
     other). *)
  (match !pin_file with
   | Some path -> Remote.preseed_pins_from_file ~pins_file:path
   | None -> ());
  Runtime.probe_observer := Primitives.probe_observe_for_store;
  Runtime.domain_cell_observer := Primitives.domain_observe_cell_for_store;
  Runtime.fenced_policy := !fenced_policy;
  (* Collect every cell observation made by the program: needed for
     stratification (LAW 30) and for --watch polling. Unconditional (not
     gated on --reconcile/--watch/--supervise): a program may call
     register-domain itself with neither flag set (Q13's "programs may
     call register-domain themselves" mode) — main.ml cannot know in
     advance whether the program it is about to run will do that, so
     collection must always be live for the stratification check
     domains.ml performs after root evaluation to see anything at all.
     The cost is one list-cons per cell read; unused when nothing
     converges. *)
  Runtime.observe_all := true;
  (* Recover any unknown-status fenced actions from a prior crash before
     applying new state (Q3 / LAW 31). Skipped under `--gc-mark`: a GC
     replay must never perform a real recovery action — see the --gc-mark
     branch below, which also skips run_domains_pass/Fenced.drain for the
     same reason (mark-by-replay is read-only on the world by construction,
     not merely by convention). *)
  if (!reconcile_root <> None || !supervise) && !gc_mark_out = None then
    Fenced.recover_unknown ~policy:!fenced_policy;


  (* ---- Q13 driver wiring (PLAN-m4-cells.md §Q13, the exit criterion) ----

     `--reconcile ROOT` auto-loads stdlib/domain-fs.pp and registers it with
     a write-cap cap-restrict'd to ROOT, wrapping the program's final value
     as {"fs" -> v}; `--supervise` likewise with stdlib/domain-proc.pp,
     {"proc" -> v}; both compose (the same v feeds both, exactly as the
     pre-Q13 code ran Reconciler.reconcile and Supervisor.reconcile on the
     SAME `last` when both flags were given). A program that calls
     register-domain itself needs none of this glue — it returns
     {name -> desired} directly, one evaluation, N domains. *)
  let read_file_content (path : string) : string =
    let ch = open_in path in
    let s = really_input_string ch (in_channel_length ch) in
    close_in ch; s
  in
  (* Minimal pp string-literal quoting for embedding an OCaml-computed path
     into synthetic glue source text (reader.ml supports the usual backslash
     and double-quote escapes; anything else passes through) — NOT
     Codec.quote_string, which is a different (store-line) escaping
     dialect. *)
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
  in
  let uses_domains () = !reconcile_root <> None || !supervise in
  (* (source-tag, content) pairs to run BEFORE the user's file(s), under the
     SAME init (Repl.execute_sources_bytecode) so the domain registrations
     they perform survive into the user program's evaluation — two
     SEPARATE execute_*_bytecode calls would each re-init and wipe
     Runtime.domain_registry (Evaluator.init resets it every fresh run). *)
  let stdlib_glue_sources () : (string * string) list =
    if not (uses_domains ()) then []
    else match Runtime.stdlib_root () with
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
          let fs_glue = match !reconcile_root with
            | None -> []
            | Some r ->
                let canon = Runtime.canonical_path r in
                (* :wo, not :rw (a documented deviation from the contract's
                   literal wording): tests/023 grants only `fs:ROOT:wo` and
                   expects a full build+restore cycle to work — the single
                   writer reading its OWN managed tree to converge is not a
                   distinct authority concern (Domain_prims.tree_observe
                   accepts read-OR-write for exactly this reason), so the
                   domain's write-cap only needs to hold WRITE; requesting
                   :rw here would make cap-restrict itself reject a
                   write-only grant before the domain ever runs. *)
                [("<domain-glue:fs>", Printf.sprintf
                    "(load %s)\n(register-fs-domain %s (cap-restrict (current-capabilities) %s :wo))\n"
                    (pp_quote (Filename.concat root "domain-fs.pp"))
                    (pp_quote canon) (pp_quote canon))]
          in
          let proc_glue =
            if not !supervise then []
            else
              [("<domain-glue:proc>", Printf.sprintf
                  "(load %s)\n(register-proc-domain (current-capabilities))\n"
                  (pp_quote (Filename.concat root "domain-proc.pp")))]
          in
          common @ fs_glue @ proc_glue
  in
  (* Merge rule for the auto-wrap: --reconcile alone -> {"fs" v}; --supervise
     alone -> {"proc" v}; both -> {"fs" v, "proc" v} (both fed the SAME v,
     exactly as the two old reconcilers each separately received it). A bare
     register-domain program (neither flag) returns its own {name -> desired}
     directly — [v] unwrapped. *)
  let build_all_desired (v : Types.value) : Types.value =
    let pairs =
      (if !reconcile_root <> None then [(Types.VString "fs", v)] else [])
      @ (if !supervise then [(Types.VString "proc", v)] else [])
    in
    if pairs <> [] then Types.VMap pairs else v
  in
  (* Run every given file plus (when needed) the domain-registration glue,
     under ONE init — this is what lets `register-fs-domain`/
     `register-proc-domain`'s registration survive to reach the user's
     file. Falls back to the untouched per-file loop (today's exact
     behavior, byte-for-byte) when no domain wiring is needed at all. *)
  let run_files (files : string list) : Types.value option =
    Runtime.fenced_actions := [];
    if uses_domains () then
      let sources = stdlib_glue_sources ()
                    @ List.map (fun f -> (f, read_file_content f)) files in
      match List.rev (Repl.execute_sources_bytecode !bytecode sources) with
      | v :: _ -> Some v | [] -> None
    else
      List.fold_left (fun _ f ->
        Runtime.fenced_actions := [];
        match List.rev (Repl.execute_file_bytecode !bytecode f) with
        | v :: _ -> Some v | [] -> None) None files
  in
  let should_run_domains () =
    uses_domains () || Domains.any_write_domain_registered ()
  in
  (* M5 stage C by-hash desired-value seam (docs/PLAN-m5-distribution.md
     "Host-qualified domain distribution"): `--desired-object HASH ROOT`
     substitutes the DERIVATION of the desired-state root entirely — the
     object was already pulled (and its blob: refs with it) above, so this
     process never runs a program to compute what to converge, only to
     register domains (run_files still executes for that side effect; its
     RETURN VALUE is discarded here in favor of the synced object). Without
     `--desired-object`, behavior is EXACTLY today's: wrap the program's own
     return value via build_all_desired. *)
  let compute_all_desired (last : Types.value option) : Types.value =
    match !desired_object_args with
    | Some (hash, _) ->
        (match Store.load_object ~key:hash with
         | Some v -> v
         | None ->
             failwith (Printf.sprintf
               "pp: --desired-object %s: not found in the local store even \
                after pulling — check the shared root and that it was \
                published there via --publish-object" hash))
    | None ->
        (match last with
         | Some v -> build_all_desired v
         | None -> failwith "reconcile: the program produced no value")
  in
  (* M5 stage C host-qualified domain distribution: the LEAST-MAGIC
     detection rule the contract asks for — host-keying is opt-in ONLY via
     an explicit `--member-name <n>` flag, never inferred from a value's
     shape. Without it, [all_desired] passes through completely unchanged,
     so a program/flags that never mention --member-name (tests/018,
     tests/033, every pre-M5-stage-C test) behave byte-identically — this
     is the whole back-compat proof. With it, [all_desired] MUST be a map
     keyed by host name (string or keyword) and this indexes exactly one
     entry, handing the UNCHANGED Domains.run_all only that host's own
     {domain -> desired} slice. *)
  let select_member_slice (all_desired : Types.value) : Types.value =
    match !member_name with
    | None -> all_desired
    | Some name ->
        (match Primitives.force_deep all_desired with
         | Types.VMap kvs ->
             (match List.find_opt (fun (k, _) ->
                match k with
                | Types.VString s | Types.VKeyword s -> s = name
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
               name (Types.string_of_value other)))
  in
  let run_domains_pass (last : Types.value option) : unit =
    if should_run_domains () then begin
      Domains.run_all (select_member_slice (compute_all_desired last));
      Fenced.drain ()
    end
  in

  (* ---- Phase 2: pp graph — delegates to Store.print_graph ---- *)
  let print_graph ?(verbose = false) () = Store.print_graph ~verbose () in

  (* ---- Phase 2: --watch polling loop ----
     Run the program, snapshot observed cell hashes, poll for changes,
     re-run on change. Uses the pull scheduler in a loop — the persistent
     store's trace verification naturally skips unchanged nodes (hits)
     and recomputes changed ones (misses), proving the store-level collapse
     between --watch and --once modes. *)
  let snapshot_cell_hashes (cell_ids : string list) : (string * string) list =
    List.filter_map (fun id ->
      match Store.observe_cell id with
      | Some h -> Some (id, h) | None -> None) cell_ids
  in
  let watch_loop ~files ~interval ~stabilize =
    Runtime.observe_all := true;
    let last_desired = ref None in
    let run_program () =
      (* Clear in-memory state for a fresh evaluation. The persistent store
         survives — this is the store-level collapse. run_files itself
         calls Vm.init ()/Repl.init () (via execute_sources_bytecode /
         execute_file_bytecode). *)
      Hashtbl.clear Store.run_pins;  (* clear pinned cell observations *)
      Hashtbl.clear Runtime.probe_values;  (* M4: probes re-evaluate fresh each pass *)
      Hashtbl.clear Runtime.sealed_pins;   (* M4: sealed bytes never survive a pass *)
      Runtime.observed_all := [];     (* clear collected observations *)
      Runtime.current_capabilities := !Runtime.initial_capabilities;
      (* Re-read and execute the program (plus, if --reconcile/--supervise
         is active, the domain-registration glue — run_files/uses_domains). *)
      let last = run_files files in
      last_desired := last;
      run_domains_pass last;
      (* Collect the cells we need to poll and snapshot their current hashes. *)
      let cell_ids = List.sort_uniq compare (List.map fst !(Runtime.observed_all)) in
      snapshot_cell_hashes cell_ids
    in
    let run_program_stabilize ~prev_snapshot changed_cells =
      let rev = Store.build_reverse_index () in
      let dirty = Store.dirty_keys_for changed_cells rev in
      Stabilize.reset_dirty dirty;
      Runtime.keep_thunks := true;  (* set BEFORE run_files's internal init *)
      Hashtbl.clear Store.run_pins;  (* fresh world observations, not last run's pins *)
      Hashtbl.clear Runtime.probe_values;  (* M4: probes re-evaluate fresh each pass *)
      Hashtbl.clear Runtime.sealed_pins;   (* M4: sealed bytes never survive a pass *)
      Runtime.observed_all := [];
      Runtime.current_capabilities := !Runtime.initial_capabilities;
      let last = run_files files in
      last_desired := last;
      run_domains_pass last;
      let cell_ids = List.sort_uniq compare (List.map fst !(Runtime.observed_all)) in
      let new_obs = snapshot_cell_hashes cell_ids in
      let new_set = List.map fst new_obs in
      let prev_clean = List.filter (fun (id, _) -> not (List.mem id new_set)) prev_snapshot in
      new_obs @ prev_clean
    in
    (* First iteration: cold run. *)
    if stabilize then begin
      Runtime.keep_thunks := false;
      Stabilize.clear_side_table ()
    end;
    let snapshot = run_program () in
    let rec loop snapshot =
      begin try Unix.sleepf interval
        with _ -> Unix.sleep 1 end;
      (* Clear run pins so observe_cell reads the current world, not the
         snapshot from the last run (Q11 CAS-ingest pins the first read). *)
      Hashtbl.clear Store.run_pins;
      Hashtbl.clear Runtime.probe_values;  (* M4: probes re-evaluate fresh each pass *)
      Hashtbl.clear Runtime.sealed_pins;   (* M4: sealed bytes never survive a pass *)
      (* Detect cell changes FIRST, before reconcile work, so config edits
         are noticed promptly. Then reconcile processes only when no cell
         changed — this still restarts killed services within one interval. *)
      let changed_cells =
        List.filter_map (fun (cell_id, recorded_hash) ->
          match Store.observe_cell cell_id with
          | Some h when h <> recorded_hash -> Some cell_id
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
           write-domain is re-observed/re-diffed/re-applied on every tick,
           not just proc — a killed service or an externally-drifted file
           is caught within one poll interval either way. Cheap when
           nothing actually changed: the plan cache (Domains.compute_plan)
           makes an unchanged pass a cache hit, not a re-walk. *)
        (match !last_desired with
         | Some v -> run_domains_pass (Some v)
         | None -> ());
        loop snapshot
      end
    in
    loop snapshot
  in
  (* pp graph: just scan and print, no file needed. *)
  if !graph_mode then (print_graph (); exit 0);
  (* ---- M5 stage A: cluster transport/token CLI seam ----
     Administrative/test entries: each does its one thing and exits.
     Errors (bad token, corrupt/tampered artifact, missing secret) propagate
     as Failure/Transport.Transport_integrity_error to the top-level handler
     below, printed uniformly as "pp: error: ...". *)
  if !cluster_init_mode then (Token.init (); exit 0);
  (match !mint_token_args with
   | Some (out, ttl) ->
       let secret = Token.load_secret () in
       let cluster_id = Token.load_cluster_id () in
       let token = Token.mint ~secret ~cluster_id ~specs:(List.rev !grants) ~ttl_seconds:ttl in
       Store.atomic_write out token;
       exit 0
   | None -> ());
  (match !transport_push_args with
   | Some (kind, id, root) ->
       (match kind with
        | "object" -> Transport.LocalDir.push_object root ~hash:id
        | "blob" -> Transport.LocalDir.push_blob root ~hash:id
        | "trace" -> Transport.LocalDir.push_trace root ~key:id
        | _ -> failwith ("pp --transport-push: unknown artifact kind " ^ kind));
       exit 0
   | None -> ());
  (match !transport_pull_args with
   | Some (kind, id, root) ->
       (match kind with
        | "object" -> Transport.LocalDir.pull_object root ~hash:id
        | "blob" -> Transport.LocalDir.pull_blob root ~hash:id
        | "trace" -> Transport.LocalDir.pull_trace root ~key:id
        | _ -> failwith ("pp --transport-pull: unknown artifact kind " ^ kind));
       exit 0
   | None -> ());
  (match !serve_hit_args with
   | Some (key, token_file, shared_root, reply_file) ->
       let token_text = read_file_content token_file in
       let reply = Transport.serve_hit ~key ~token_text ~shared_root in
       Store.atomic_write reply_file reply;
       exit 0
   | None -> ());
  (match !recv_hit_args with
   | Some (reply_file, shared_root) ->
       let reply_text = read_file_content reply_file in
       (match Transport.recv_hit ~reply_text ~shared_root with
        | Transport.RHit { key; result_hash; _ } ->
            Printf.printf "recv-hit: hit key=%s result=%s\n" key result_hash
        | Transport.RMiss key -> Printf.printf "recv-hit: miss key=%s\n" key
        | Transport.RDeny (key, reason) ->
            Printf.printf "recv-hit: deny key=%s reason=%s\n" key reason);
       exit 0
   | None -> ());
  (* ---- M5 stage C: `pp gc` (explicit, never automatic) ---- *)
  if !gc_mode then (Store_gc.run ~grace_seconds:!gc_grace_seconds; exit 0);
  (* ---- M5 stage C: `--publish-object <shared-root>` — the by-hash
     desired-value PUBLISH seam's dispatcher side (docs/PLAN-m5-
     distribution.md "Host-qualified domain distribution"): run the program
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
       let last = run_files (List.rev !files) in
       (match last with
        | None -> failwith "pp: --publish-object: the program produced no value"
        | Some v ->
            let forced = Primitives.force_deep v in
            let hash = Types.hash_value forced in
            (match Codec.encode_value forced with
             | None ->
                 failwith "pp: --publish-object: the program's value contains \
                           code (a closure/thunk/handle) and cannot be \
                           published as data"
             | Some _ -> Store.store_object ~key:hash ~value:forced);
            List.iter (fun h -> try Transport.LocalDir.push_blob shared_root ~hash:h with _ -> ())
              (Blobref.blob_refs_in forced);
            Transport.LocalDir.push_object shared_root ~hash;
            Printf.printf "publish-object: %s\n" hash);
       exit 0
   | None -> ());
  (* ---- M5 stage C: `--gc-mark <outfile>` — internal, only `pp gc`'s own
     replay subprocess (src/store_gc.ml) sets this. Runs the recorded root
     program EXACTLY as a live pass would (registration glue, the user's
     file(s), the same --grant/--bytecode/--reconcile/--supervise/
     --member-name/--desired-object flags) so every Store.hit it makes
     marks its trace/object/blob(s) live (Store.gc_marking, turned on
     earlier, right after Store.init) — then STOPS: no run_domains_pass (no
     domain apply), no Fenced.recover_unknown/drain (already skipped
     above). This is what makes replay read-only on the world by
     construction: nothing below this branch ever runs. *)
  (match !gc_mark_out with
   | Some out ->
       let last = run_files (List.rev !files) in
       (try
          let all = select_member_slice (compute_all_desired last) in
          let forced = Primitives.force_deep all in
          Store.mark_live ("object:" ^ Types.hash_value forced);
          List.iter (fun h -> Store.mark_live ("blob:" ^ h)) (Blobref.blob_refs_in forced)
        with _ ->
          (* A root whose desired-state can no longer be derived at all
             (e.g. should_run_domains () is false for this replay) still
             marks whatever Store.hit calls run_files itself made above —
             conservative, not a hard failure of the whole replay. *)
          ());
       let marks = Hashtbl.fold (fun k () acc -> k :: acc) Store.gc_live [] in
       Store.atomic_write out (String.concat "\n" marks ^ (if marks = [] then "" else "\n"));
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
  (match !eval_str, !files with
  | Some e, [] ->
      if !diff then begin
        Printf.eprintf "--diff not supported with -e\n"; exit 1
      end;
      let results = Repl.execute_string_bytecode !bytecode e in
      List.iter (fun v ->
        Printf.printf "%s\n" (Types.string_of_value v)
      ) results
  | None, [] ->
      if !bytecode then Repl.repl_bytecode ()
      else Repl.repl ()
  | _, files ->
      let files = List.rev files in
      if !watch then
        watch_loop ~files ~interval:!watch_interval ~stabilize:!stabilize
      else if !diff then begin
        List.iter (fun f ->
          let tw_results = Repl.execute_file f in
          let bc_results = Repl.execute_file_bytecode true f in
          let tw_strings = List.map Types.string_of_value tw_results in
          let bc_strings = List.map Types.string_of_value bc_results in
          if tw_strings <> bc_strings then begin
            Printf.eprintf "--diff mismatch in %s\n" f;
            Printf.eprintf "tree-walker (%d values):\n" (List.length tw_strings);
            List.iter (Printf.eprintf "  %s\n") tw_strings;
            Printf.eprintf "bytecode (%d values):\n" (List.length bc_strings);
            List.iter (Printf.eprintf "  %s\n") bc_strings;
            exit 1
          end
        ) files
      end else begin
        let last = run_files files in
        run_domains_pass last;
        (* M6 stage B: `--dump-pins <path>` — after the canonical run
           completes (this plain non-watch, non-remote-node branch only;
           the other branches have their own, different, run shapes),
           write every Store.run_pins entry as a `(pin ...)` line and every
           Runtime.probe_values entry as a `(pin-probe ...)` line
           (docs/PLAN-m6-demo.md "Stage B — the pin seam"). A probe value
           Codec.encode_value can't encode (code/a handle/a sealed secret)
           is skipped — mirrors how a node's RESULT value already treats
           non-data (--publish-object's own "cannot be published as data"
           check) — logged, not a hard failure, since the run itself
           already succeeded. Placed BEFORE the --check re-run below,
           which clears/repopulates Store.run_pins for its own serial
           comparison — dumping first captures exactly this run's own
           observations, not the re-run's. *)
        (match !dump_pins_file with
         | Some path ->
             let buf = Buffer.create 256 in
             Hashtbl.iter (fun cell hash -> Buffer.add_string buf (Remote.pin_line cell hash))
               Store.run_pins;
             Hashtbl.iter (fun name v ->
               match Codec.encode_value v with
               | Some text -> Buffer.add_string buf (Remote.pin_probe_line name text)
               | None ->
                   Printf.eprintf
                     "[dump-pins] skipping non-data probe value for %s (code/handle/sealed)\n%!"
                     name)
               Runtime.probe_values;
             Store.atomic_write path (Buffer.contents buf)
         | None -> ());
        (* Phase 3 schedule-transparency audit (D17 class 1 / LAW 26/34's
           promised --check): a result-transparent handler must never change
           WHAT a program computes, only where/when it runs. Under --check
           with a non-serial policy, re-run the SAME program forced Serial
           against the SAME on-disk store and compare the desired-state
           value's hash; any mismatch is exactly as unsound as the existing
           per-node volatility failure and is reported/gated the same way
           (Store.volatile_count). This is a WHOLE-PROGRAM check distinct
           from run_node_body's per-node double-run — the re-run's own
           reconcile/supervise/fenced side effects are deliberately skipped
           (only the value is compared) so a --check run never applies
           convergent state or fenced actions twice. *)
        if !Store.check_mode && !Scheduler.policy <> Scheduler.Serial then
          (match last with
           | None -> ()
           | Some v ->
               let h_scheduled = Types.hash_value v in
               let saved_policy = !Scheduler.policy in
               let policy_name = function
                 | Scheduler.Serial -> "serial"
                 | Scheduler.Parallel n -> Printf.sprintf "parallel:%d" n
                 | Scheduler.Race n -> Printf.sprintf "race:%d" n
                 | Scheduler.Remote m -> Printf.sprintf "remote:%s" m
               in
               Scheduler.policy := Scheduler.Serial;
               Hashtbl.clear Store.run_pins;
               Runtime.current_capabilities := !Runtime.initial_capabilities;
               (* Deliberately reuses run_files (so a --reconcile/--supervise
                  program's domain registration is available identically to
                  the scheduled run) but never calls run_domains_pass — this
                  comparison is value-only; convergent/fenced side effects
                  must not apply twice. *)
               let last_serial = run_files files in
               Scheduler.policy := saved_policy;
               (match last_serial with
                | None -> ()
                | Some v2 ->
                    if Types.hash_value v2 <> h_scheduled then begin
                      incr Store.volatile_count;
                      Printf.eprintf
                        "[check] schedule non-transparent: %s and serial re-runs produced different desired-state hashes\n%!"
                        (policy_name saved_policy)
                    end))
      end);

  (* M5 stage B: after running the program (whatever nodes that forced,
     including — but not limited to — the dispatcher's assigned batch keys;
     duplicate/extra computation here is sound, contract's "advisory
     responsibility partition"), serve each assigned key back to the
     dispatcher via the UNCHANGED stage-A Transport.serve_hit, once per key,
     against THIS process's own now-populated store. *)
  (match !remote_node_args with
   | Some (token_file, _, shared_root, keys_file, reply_file) ->
       let token_text = Store.read_raw token_file in
       Remote.serve_assigned_keys ~token_text ~keys_file ~shared_root ~reply_file
   | None -> ());

  (* --check verdict: any volatile node fails the audit (LAW 38). *)
  if !Store.check_mode && !Store.volatile_count > 0 then begin
    Printf.eprintf "[check] FAIL: %d volatile node(s) flagged\n%!"
      !Store.volatile_count;
    exit 1
  end

(* Uncaught runtime errors print as one clean line, not an OCaml backtrace
   header (ROADMAP §1 error-message ergonomics). Exit 1. *)
let () =
  try main () with
  | Types.Pp_exit n -> exit n
  | Failure msg | Types.Capability_error msg | Sys_error msg
  | Transport.Transport_integrity_error msg ->
      Printf.eprintf "pp: error: %s\n%!" msg;
      exit 1
