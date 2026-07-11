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

  let rec parse = function
    | "--" :: rest ->
        (* Everything after `--` is the program's argv (the `argv` builtin). *)
        Runtime.program_argv := rest
    | "--bytecode" :: rest -> bytecode := true; parse rest
    | "--diff" :: rest -> diff := true; bytecode := true; parse rest
    | "--update" :: rest -> Island.update_mode := true; parse rest
    | "--grant" :: grant :: rest -> grants := grant :: !grants; parse rest
    | "--reconcile" :: root :: rest -> reconcile_root := Some root; parse rest
    | "--supervise" :: rest -> supervise := true; parse rest
    | "why" :: rest | "--why" :: rest -> Store.why_mode := true; parse rest
    | "--no-cache" :: rest -> Store.no_cache := true; parse rest
    | "--check" :: rest -> Store.check_mode := true; parse rest
    | "-e" :: e :: rest -> eval_str := Some e; parse rest
    | "--version" :: _ | "-v" :: _ ->
        Printf.printf "pp v0.1.0\n"; exit 0
    | "--help" :: _ | "-h" :: _ ->
        Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\n";
        Printf.printf "Usage:\n";
        Printf.printf "  pp                       Start REPL\n";
        Printf.printf "  pp <file.pp>             Run a pp source file\n";
        Printf.printf "  pp --bytecode <file.pp>  Run via bytecode VM\n";
        Printf.printf "  pp --diff <file.pp>      Run both backends and diff\n";
        Printf.printf "  pp -e '<expr>'           Evaluate an expression\n";
        Printf.printf "  pp --grant <spec>        Grant capability (fs:/path:rw, net:tcp, process)\n";
        Printf.printf "  pp --reconcile <root>    Materialize the program's map value under <root>\n";
        Printf.printf "  pp --supervise <file.pp>  Reconcile program's process-map value (use with --watch)\n";
        Printf.printf "  pp why <file.pp>         Explain node cache hits/misses (capability-filtered)\n";
        Printf.printf "  pp --no-cache <file.pp>  Skip cache reads (recompute); results still stored\n";
        Printf.printf "  pp --check <file.pp>     Determinism audit: run each node twice, flag volatile\n";
        Printf.printf "  pp --once <file.pp>        Run once and exit (explicit; default behavior)\n";
        Printf.printf "  pp --watch <file.pp>       Run, then watch cell changes and re-evaluate\n";
        Printf.printf "  pp --watch --stabilize <file>  Watch with push stabilize (dirty-propagation)\n";
        Printf.printf "  pp graph                  Print the cell->node dependency graph from traces\n";
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
        in Types.CapFilesystem { path; mode = m }
    | ["net"; protocol] ->
        Types.CapNetwork { protocol }
    | ["process"] ->
        Types.CapProcess
    | _ -> failwith ("invalid --grant spec: " ^ spec)
  in
  let initial_caps = List.map parse_grant (List.rev !grants) in
  Runtime.initial_capabilities := initial_caps;
  (* Loader authority bound (Q6/D8c): the interpreter may load source from
     the CLI-named programs' directories, the cwd, and ~/.pp — nothing else. *)
  Runtime.source_roots :=
    Sys.getcwd ()
    :: List.map (fun f ->
         Filename.dirname
           (if Filename.is_relative f then Filename.concat (Sys.getcwd ()) f
            else f))
         !files;
  Store.init ();
  Runtime.proc_observer := Supervisor.observe_proc;
  (* Collect every cell observation made by the program: needed for
     --reconcile stratification (LAW 30) and for --watch polling. *)
  if !reconcile_root <> None || !watch || !supervise then Runtime.observe_all := true;


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
  let watch_loop ~bytecode ~reconcile_root ~supervise ~files ~interval ~stabilize =
    Runtime.observe_all := true;
    let last_desired = ref None in
    let apply_reconciliation last =
      (match reconcile_root, last with
       | Some root, Some v -> Reconciler.reconcile ~root v
       | None, _ -> ()
       | Some _, None -> failwith "reconcile: the program produced no value");
      (if supervise then
         match last with
         | Some v -> Supervisor.reconcile v
         | None -> failwith "supervise: the program produced no value")
    in
    let run_program () =
      (* Clear in-memory state for a fresh evaluation. The persistent store
         survives — this is the store-level collapse. *)
      if bytecode then Vm.init ()  (* clears thunk_store, globals, etc. *)
      else Repl.init ();            (* clears thunk_store, resets global_env *)
      Hashtbl.clear Store.run_pins;  (* clear pinned cell observations *)
      Runtime.observed_all := [];     (* clear collected observations *)
      Runtime.current_capabilities := !Runtime.initial_capabilities;
      (* Re-read and execute the program. *)
      let last = List.fold_left (fun _ f ->
        match List.rev (Repl.execute_file_bytecode bytecode f) with
        | v :: _ -> Some v | [] -> None) None files in
      last_desired := last;
      apply_reconciliation last;
      (* Collect the cells we need to poll and snapshot their current hashes. *)
      let cell_ids = List.sort_uniq compare (List.map fst !(Runtime.observed_all)) in
      snapshot_cell_hashes cell_ids
    in
    let run_program_stabilize ~prev_snapshot changed_cells =
      let rev = Store.build_reverse_index () in
      let dirty = Store.dirty_keys_for changed_cells rev in
      Stabilize.reset_dirty dirty;
      Runtime.keep_thunks := true;  (* set BEFORE execute_file_bytecode's internal init *)
      Hashtbl.clear Store.run_pins;  (* fresh world observations, not last run's pins *)
      Runtime.observed_all := [];
      Runtime.current_capabilities := !Runtime.initial_capabilities;
      (* execute_file_bytecode calls init internally — keep_thunks gates thunk_store *)
      let last = List.fold_left (fun _ f ->
        match List.rev (Repl.execute_file_bytecode bytecode f) with
        | v :: _ -> Some v | [] -> None) None files in
      last_desired := last;
      apply_reconciliation last;
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
        (* Process supervision: re-reconcile every tick so a killed service
           is restarted within one interval even if no input cell changed. *)
        if supervise then
          (match !last_desired with
           | Some v -> Supervisor.reconcile v
           | None -> ());
        loop snapshot
      end
    in
    loop snapshot
  in
  (* pp graph: just scan and print, no file needed. *)
  if !graph_mode then (print_graph (); exit 0);
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
        watch_loop ~bytecode:!bytecode ~reconcile_root:!reconcile_root
          ~supervise:!supervise ~files ~interval:!watch_interval ~stabilize:!stabilize
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
        let last =
          List.fold_left (fun _ f ->
            match List.rev (Repl.execute_file_bytecode !bytecode f) with
            | v :: _ -> Some v | [] -> None) None files
        in
        (match !reconcile_root, last with
         | Some root, Some v -> Reconciler.reconcile ~root v
         | None, _ | Some _, None -> ());
        (if !supervise then
           match last with
           | Some v -> Supervisor.reconcile v
           | None -> failwith "supervise: the program produced no value")
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
