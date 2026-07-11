(* pp fenced-effect executor (Q3 / LAW 31).

   Fenced effects are non-convergent, irreversible actions (send email, charge
   card, post webhook).  They may not appear in node bodies; they are sequenced
   by the reconciler/supervisor after convergent state is applied, one pass at
   a time, through an intent/done journal.

   Action identity within a pass: key = H(epoch, kind, spec-hash).  The epoch
   is a fresh nonce per reconcile pass so the same action in a later pass has a
   different key.  The spec value is persisted by content hash so recovery can
   re-execute an unknown-status action with the same inputs. *)

open Types

let current_epoch = ref ""

let epoch_counter = ref 0

let new_epoch () : unit =
  incr epoch_counter;
  current_epoch := Hasher.hash_string
      (Printf.sprintf "%f-%d-%d" (Unix.gettimeofday ()) (Unix.getpid ())
         !epoch_counter)

let ensure_epoch () = if !current_epoch = "" then new_epoch ()

let action_key ~(epoch : string) ~(kind : string) ~(spec_hash : string) : string =
  Hasher.hash_concat ["fenced"; epoch; kind; spec_hash]

let hash_spec (spec : value) : string =
  Hasher.hash_value (!Runtime.force_hook spec)

(* Deep-force and validate that the spec is a map. *)
let force_spec_map (spec : value) : (value * value) list =
  match !Runtime.force_hook spec with
  | VMap kvs -> kvs
  | other -> failwith ("fenced: spec must be a map, got " ^ string_of_value other)

(* A fenced action may optionally name a shell command under the "run" key in
   its spec map.  The value must be a list or vector of strings [cmd arg ...],
   or a single string interpreted as a shell command.  If no "run" key is
   present, the action is a pure record-and-mark: it is journaled and marked
   done with a nil result.  This lets users implement the actual executor
   externally while still getting the WAL guarantee. *)
let run_command (spec : value) : value =
  let kvs = force_spec_map spec in
  let find key =
    List.find_opt (fun (k, _) ->
      match !Runtime.force_hook k with
      | VString s | VKeyword s | VSymbol s -> s = key
      | _ -> false)
      kvs
  in
  match find "run" with
  | None -> VMap []
  | Some (_, v) ->
      let argv =
        match !Runtime.force_hook v with
        | VNil -> []
        | VPair _ as lst ->
            let rec collect = function
              | VNil -> []
              | VPair (a, d) ->
                  (match !Runtime.force_hook a with
                   | VString s | VKeyword s | VSymbol s -> s
                   | other -> failwith ("fenced: run argv must be strings, got " ^ string_of_value other))
                  :: collect d
              | other -> failwith ("fenced: run must be a list of strings, got " ^ string_of_value other)
            in collect lst
        | VVector arr ->
            Array.to_list (Array.map (fun x ->
              match !Runtime.force_hook x with
              | VString s | VKeyword s | VSymbol s -> s
              | other -> failwith ("fenced: run argv must be strings, got " ^ string_of_value other)) arr)
        | VString s -> ["/bin/sh"; "-c"; s]
        | other -> failwith ("fenced: run must be a list/vector/string of strings, got " ^ string_of_value other)
      in
      if argv = [] then failwith "fenced: run argv is empty";
      let cmd = List.hd argv in
      let args = List.tl argv in
      let resolved =
        match Process.resolve_cmd cmd with
        | Some p -> p
        | None -> failwith ("fenced: command not found: " ^ cmd)
      in
      let env = Array.to_list (Unix.environment ()) in
      let tmp_out = Filename.temp_file "pp-fenced-out" "" in
      let tmp_err = Filename.temp_file "pp-fenced-err" "" in
      let pid =
        Unix.create_process_env resolved (Array.of_list (resolved :: args))
          (Array.of_list env) Unix.stdin
          (Unix.openfile tmp_out [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644)
          (Unix.openfile tmp_err [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644)
      in
      let (_, status) = Unix.waitpid [] pid in
      let exit_code = match status with
        | Unix.WEXITED n -> n
        | Unix.WSIGNALED n -> 128 + n
        | Unix.WSTOPPED n -> 128 + n
      in
      let read_file path =
        try
          let ic = open_in path in
          let s = really_input_string ic (in_channel_length ic) in
          close_in ic; Sys.remove path; s
        with _ -> (try Sys.remove path with _ -> ()); ""
      in
      let out = read_file tmp_out in
      let err = read_file tmp_err in
      VMap [(VString "exit", VInt exit_code);
            (VString "out", VString out);
            (VString "err", VString err)]

let result_hash (v : value) : string = Hasher.hash_value v

(* Register a fenced action from user code.  This only stores it for later
   execution by the reconciler; it does not run anything or touch the journal. *)
let register (kind : string) (spec : value) : unit =
  if !Runtime.trace_stack <> [] then
    failwith "fenced: fenced effects may not appear inside node bodies (LAW 31)";
  Runtime.fenced_actions := (kind, spec) :: !Runtime.fenced_actions

(* Execute one current-pass fenced action: compute a fresh key from the current
   epoch, journal intent, run, journal done. *)
let execute_current ~(kind : string) ~(spec : value) : unit =
  ensure_epoch ();
  let spec_hash = hash_spec spec in
  let key = action_key ~epoch:!current_epoch ~kind ~spec_hash in
  if Store.fenced_is_done key then ()
  else begin
    Store.store_fenced_spec ~hash:spec_hash spec;
    Store.journal_append
      (Printf.sprintf "intent fenced %s %s %s %s" key !current_epoch kind spec_hash);
    let result = run_command spec in
    Store.journal_append
      (Printf.sprintf "done fenced %s %s" key (result_hash result))
  end

(* Execute a single unknown-status fenced action during recovery.  Uses the
   key/epoch/kind/spec-hash stored in the journal; loads the persisted spec by
   hash so the action runs with the same inputs. *)
let execute_recovery ~(policy : string) ~(entry : Store.fenced_entry) : unit =
  let spec =
    match Store.load_fenced_spec entry.Store.fe_spec_hash with
    | Some v -> v
    | None ->
        (* Spec missing: we cannot safely retry.  Abort regardless of policy. *)
        VMap [(VString "kind", VString entry.Store.fe_kind);
              (VString "spec-hash", VString entry.Store.fe_spec_hash);
              (VString "error", VString "spec missing from store")]
  in
  let result =
    if policy = "retry" then
      run_command spec
    else if policy = "abort" then
      VMap [(VString "aborted", VBool true);
            (VString "policy", VString "abort");
            (VString "kind", VString entry.Store.fe_kind);
            (VString "spec-hash", VString entry.Store.fe_spec_hash)]
    else if policy = "ask" then begin
      if not (Unix.isatty Unix.stdin) then
        failwith ("fenced: unknown-status policy is 'ask' but stdin is not a tty; " ^
                  "use --fenced-policy retry|abort for non-interactive use");
      Printf.printf "Fenced action %s (kind=%s) has unknown status.  Retry? [y/N]: %!"
        entry.Store.fe_key entry.Store.fe_kind;
      let line = try input_line stdin with End_of_file -> "n" in
      if String.lowercase_ascii line = "y" then run_command spec
      else VMap [(VString "aborted", VBool true);
                 (VString "policy", VString "ask");
                 (VString "kind", VString entry.Store.fe_kind)]
    end else
      failwith ("fenced: unknown --fenced-policy: " ^ policy)
  in
  Store.journal_append
    (Printf.sprintf "done fenced %s %s" entry.Store.fe_key (result_hash result))

(* Resolve any unknown-status fenced actions from the journal before normal
   reconciliation proceeds.  The recovered epoch becomes the epoch for the
   current pass, so a subsequently registered action with the same kind/spec
   deduplicates against the recovered intent. *)
let recover_unknown ~(policy : string) : unit =
  let unknowns = Store.find_unknown_fenced () in
  if unknowns <> [] then
    Printf.eprintf "[fenced] %d unknown-status action(s) in journal; applying policy=%s\n%!"
      (List.length unknowns) policy;
  List.iter (fun entry ->
    execute_recovery ~policy ~entry;
    current_epoch := entry.Store.fe_epoch) unknowns

(* Drain all fenced actions registered during this evaluation.  Called once
   per reconcile pass, after all convergent fs/proc work.  Uses an existing
   epoch when resuming a crashed pass (set by recover_unknown); otherwise
   generates a fresh epoch.  The epoch is cleared at the end so the next pass
   starts fresh. *)
let drain ~(policy : string) : unit =
  ensure_epoch ();
  let actions = List.rev !Runtime.fenced_actions in
  Runtime.fenced_actions := [];
  List.iter (fun (kind, spec) -> execute_current ~kind ~spec) actions;
  current_epoch := ""
