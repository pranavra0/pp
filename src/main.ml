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
              | _ -> failwith ("invalid --schedule spec: " ^ spec)));
        parse rest
    | "island-pins" :: f :: rest -> island_pins_file := Some f; parse rest
    | "--grant" :: grant :: rest -> grants := grant :: !grants; parse rest
    | "--reconcile" :: root :: rest -> reconcile_root := Some root; parse rest
    | "--supervise" :: rest -> supervise := true; parse rest
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
        Printf.printf "  pp --schedule serial|parallel:N|race:N  Node-miss dispatch policy (default: serial)\n";
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

  (* Parse --grant specs into capabilities *)
  let parse_grant spec =
    match String.split_on_char ':' spec with
    | ["fs"; path; mode] ->
        let m = match mode with
          | "ro" -> Types.Read | "rw" -> Types.ReadWrite | "wo" -> Types.Write
          | _ -> failwith ("invalid fs mode in --grant: " ^ mode)
        in
        (* SPEC LAW 23 / DESIGN §2.1: canonicalize at the mint, so every
           downstream comparison (authority checks, `tree:` cells built from
           granted paths) already sees the same spelling a cell would. *)
        Types.CapFilesystem { path = Runtime.canonical_path path; mode = m }
    | ["net"; host] ->
        Types.CapNetwork { host; port = None }
    | ["net"; host; port] ->
        (match int_of_string_opt port with
         | Some p -> Types.CapNetwork { host; port = Some p }
         | None -> failwith ("invalid port in --grant net spec: " ^ spec))
    | ["secret"; path] ->
        (* SPEC LAW 23 / DESIGN §2.1: canonicalize at the mint, exactly like
           fs grants — so a secret grant spelled differently from a later
           read (symlink, trailing slash) still authorizes it. *)
        Types.CapSecret { path = Runtime.canonical_path path }
    | ["process"] ->
        Types.CapProcess
    | _ -> failwith ("invalid --grant spec: " ^ spec)
  in
  let initial_caps = List.map parse_grant (List.rev !grants) in
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
     applying new state (Q3 / LAW 31). *)
  if !reconcile_root <> None || !supervise then
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
  let run_domains_pass (last : Types.value option) : unit =
    if should_run_domains () then begin
      (match last with
       | Some v -> Domains.run_all (build_all_desired v)
       | None -> failwith "reconcile: the program produced no value");
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
  | Failure msg | Types.Capability_error msg | Sys_error msg ->
      Printf.eprintf "pp: error: %s\n%!" msg;
      exit 1
