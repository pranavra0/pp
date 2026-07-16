(* pp fenced-effect executor (LAW 31).

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
  Types.hash_value (Backend.r.force spec)

(* Deep-force and validate that the spec is a map. *)
let force_spec_map (spec : value) : (value * value) list =
  match Backend.r.force spec with
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
      match Backend.r.force k with
      | VString s | VKeyword s | VSymbol s -> s = key
      | _ -> false)
      kvs
  in
  match find "run" with
  | None -> VMap []
  | Some (_, v) ->
      let argv =
        match Backend.r.force v with
        | VNil -> []
        | VPair _ as lst ->
            let rec collect = function
              | VNil -> []
              | VPair (a, d) ->
                  (match Backend.r.force a with
                   | VString s | VKeyword s | VSymbol s -> s
                   | other -> failwith ("fenced: run argv must be strings, got " ^ string_of_value other))
                  :: collect d
              | other -> failwith ("fenced: run must be a list of strings, got " ^ string_of_value other)
            in collect lst
        | VVector arr ->
            Array.to_list (Array.map (fun x ->
              match Backend.r.force x with
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

let result_hash (v : value) : string = Types.hash_value v

let register (kind : string) (spec : value) : unit =
  if Effect.perform Runtime.In_node then
    failwith "fenced: fenced effects may not appear inside node bodies (LAW 31)";
  let forced = Force_deep.force_deep_plain spec in
  (match Codec.encode_value forced with
   | Some _ -> ()
   | None ->
       failwith ("fenced: spec for kind '" ^ kind ^
                 "' is not serializable data (contains a closure, thunk, or " ^
                 "other code/handle value) — a fenced action's spec must be " ^
                 "plain data to be recoverable after a crash"));
  (* Store the already-forced spec: hash_spec/run_command/store_fenced_spec
     downstream (execute_current) must see the same data this check saw, or
     store_fenced_spec's own encode could see unforced thunks again and
     silently drop the write. force_hook is idempotent on non-thunk values,
     so re-forcing [forced] later is a no-op. *)
  Runtime.fenced_actions := (kind, forced) :: !Runtime.fenced_actions

(* Execute one current-pass fenced action: compute a fresh key from the current
   epoch, journal intent, run, journal done. *)
let execute_current ~(kind : string) ~(spec : value) : unit =
  ensure_epoch ();
  let spec_hash = hash_spec spec in
  let key = action_key ~epoch:!current_epoch ~kind ~spec_hash in
  if Journal.fenced_is_done key then ()
  else begin
    Store.store_fenced_spec ~hash:spec_hash spec;
    Journal.append (Journal.FencedIntent {
      key; epoch = !current_epoch; kind; spec_hash });
    let result = run_command spec in
    Journal.append (Journal.FencedDone { key; result_hash = result_hash result })
  end

(* Execute a single unknown-status fenced action during recovery.  Uses the
   key/epoch/kind/spec-hash stored in the journal; loads the persisted spec by
   hash so the action runs with the same inputs. *)
let execute_recovery ~(policy : Runtime.fenced_policy) ~(entry : Journal.fenced_entry) : unit =
  let spec =
    match Store.load_fenced_spec entry.Journal.fe_spec_hash with
    | Some v -> v
    | None ->
        (* Spec missing: we cannot safely retry.  Abort regardless of policy. *)
        VMap [(VString "kind", VString entry.Journal.fe_kind);
              (VString "spec-hash", VString entry.Journal.fe_spec_hash);
              (VString "error", VString "spec missing from store")]
  in
  let result =
    match policy with
    | Runtime.Retry -> run_command spec
    | Runtime.Abort ->
        VMap [(VString "aborted", VBool true);
              (VString "policy", VString "abort");
              (VString "kind", VString entry.Journal.fe_kind);
              (VString "spec-hash", VString entry.Journal.fe_spec_hash)]
    | Runtime.Ask ->
        if not (Unix.isatty Unix.stdin) then
          failwith ("fenced: unknown-status policy is 'ask' but stdin is not a tty; " ^
                    "use --fenced-policy retry|abort for non-interactive use");
        Printf.printf "Fenced action %s (kind=%s) has unknown status.  Retry? [y/N]: %!"
          entry.Journal.fe_key entry.Journal.fe_kind;
        let line = try input_line stdin with End_of_file -> "n" in
        if String.lowercase_ascii line = "y" then run_command spec
        else VMap [(VString "aborted", VBool true);
                   (VString "policy", VString "ask");
                   (VString "kind", VString entry.Journal.fe_kind)]
  in
  Journal.append (Journal.FencedDone {
    key = entry.Journal.fe_key; result_hash = result_hash result })

(* Resolve any unknown-status fenced actions from the journal before normal
   reconciliation proceeds.  The recovered epoch becomes the epoch for the
   current pass, so a subsequently registered action with the same kind/spec
   deduplicates against the recovered intent. *)
let recover_unknown ~(policy : Runtime.fenced_policy) : unit =
  let unknowns = Journal.find_unknown_fenced () in
  if unknowns <> [] then
    Printf.eprintf "[fenced] %d unknown-status action(s) in journal; applying policy=%s\n%!"
      (List.length unknowns) (Runtime.fenced_policy_name policy);
  List.iter (fun entry ->
    execute_recovery ~policy ~entry;
    current_epoch := entry.Journal.fe_epoch) unknowns

(* Drain all fenced actions registered during this evaluation.  Called once
   per reconcile pass, after all convergent fs/proc work.  Uses an existing
   epoch when resuming a crashed pass (set by recover_unknown); otherwise
   generates a fresh epoch.  The epoch is cleared at the end so the next pass
   starts fresh. *)
let drain () : unit =
  ensure_epoch ();
  let actions = List.rev !Runtime.fenced_actions in
  Runtime.fenced_actions := [];
  List.iter (fun (kind, spec) -> execute_current ~kind ~spec) actions;
  current_epoch := ""
