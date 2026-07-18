open Pp_kernel
(* Fenced-effect executor.

   Fenced effects are non-convergent, irreversible actions (send email, charge
   card, post webhook).  They may not appear in node bodies; they are sequenced
   by the reconciler/supervisor after convergent state is applied, one pass at
   a time, through an intent/done journal.

   Action identity within a pass: key = H(epoch, kind, spec-hash).  The epoch
   is a fresh nonce per reconcile pass so the same action in a later pass has a
   different key.  The spec value is persisted by content hash so recovery can
   re-execute an unknown-status action with the same inputs. *)

open Core_model

type recovery_decision = Retry | Abort

let force value =
  Session.force (Effect.perform Dynamic_scope.Get_session) value

let new_epoch () : unit =
  let session = Effect.perform Dynamic_scope.Get_session in
  let nonce = Session.next_fenced_epoch_nonce session in
  Session.start_fenced_epoch session (Hasher.hash_string
      (Printf.sprintf "%f-%d-%d" (Unix.gettimeofday ()) (Unix.getpid ()) nonce))

let ensure_epoch () =
  if Session.fenced_epoch (Effect.perform Dynamic_scope.Get_session) = "" then new_epoch ()

let action_key ~(epoch : string) ~(kind : string) ~(spec_hash : string) : string =
  Hasher.hash_concat ["fenced"; epoch; kind; spec_hash]

let hash_spec (spec : value) : string =
  Identity.hash_value (force spec)

(* Deep-force and validate that the spec is a map. *)
let force_spec_map (spec : value) : (value * value) list =
  match force spec with
  | VMap kvs -> kvs
  | other -> failwith ("fenced: spec must be a map, got " ^ Presentation.string_of_value other)

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
      match force k with
      | VString s | VKeyword s | VSymbol s -> s = key
      | _ -> false)
      kvs
  in
  match find "run" with
  | None -> VMap []
  | Some (_, v) ->
      let argv =
        match force v with
        | VNil -> []
        | VPair _ as lst ->
            let rec collect = function
              | VNil -> []
              | VPair (a, d) ->
                  (match force a with
                   | VString s | VKeyword s | VSymbol s -> s
                   | other -> failwith ("fenced: run argv must be strings, got " ^ Presentation.string_of_value other))
                  :: collect d
              | other -> failwith ("fenced: run must be a list of strings, got " ^ Presentation.string_of_value other)
            in collect lst
        | VVector arr ->
            Array.to_list (Array.map (fun x ->
              match force x with
              | VString s | VKeyword s | VSymbol s -> s
              | other -> failwith ("fenced: run argv must be strings, got " ^ Presentation.string_of_value other)) arr)
        | VString s -> ["/bin/sh"; "-c"; s]
        | other -> failwith ("fenced: run must be a list/vector/string of strings, got " ^ Presentation.string_of_value other)
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
        let fd_out = Unix.openfile tmp_out [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
        Fun.protect
          ~finally:(fun () -> Unix.close fd_out)
          (fun () ->
            let fd_err = Unix.openfile tmp_err [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o644 in
            Fun.protect
              ~finally:(fun () -> Unix.close fd_err)
              (fun () ->
                Unix.create_process_env resolved (Array.of_list (resolved :: args))
                  (Array.of_list env) Unix.stdin fd_out fd_err))
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
          let s = Fun.protect
            ~finally:(fun () -> close_in_noerr ic)
            (fun () -> really_input_string ic (in_channel_length ic)) in
          (try Sys.remove path with Sys_error _ -> ()); s
        with Sys_error _ | Unix.Unix_error _ | End_of_file ->
          (try Sys.remove path with Sys_error _ -> ()); ""
      in
      let out = read_file tmp_out in
      let err = read_file tmp_err in
      VMap [(VString "exit", VInt exit_code);
            (VString "out", VString out);
            (VString "err", VString err)]

let result_hash (v : value) : string = Identity.hash_value v

let register (kind : string) (spec : value) : unit =
  if Effect.perform Dynamic_scope.In_node then
    failwith "fenced: fenced effects may not appear inside node bodies (LAW 31)";
  let forced = Force_deep.force_deep_plain ~force spec in
  (match Codec.encode_value forced with
   | Some _ -> ()
   | None ->
       failwith ("fenced: spec for kind '" ^ kind ^
                 "' is not serializable data (contains a closure, thunk, or " ^
                 "other code/handle value) — a fenced action's spec must be " ^
                 "plain data to be recoverable after a crash"));
  (* Persist the already-forced spec: hashing, execution, and persistence
     downstream (execute_current) must see the same data this check saw, or
     must see the same value, or the repository encoder could see thunks and
     silently drop the write. Forcing is idempotent on non-thunk values,
     so re-forcing [forced] later is a no-op. *)
  Session.add_fenced_action (Effect.perform Dynamic_scope.Get_session) (kind, forced)

(* Execute one current-pass fenced action: compute a fresh key from the current
   epoch, journal intent, run, journal done. *)
let execute_current ~(kind : string) ~(spec : value) : unit =
  ensure_epoch ();
  let spec_hash = hash_spec spec in
  let epoch = Session.fenced_epoch (Effect.perform Dynamic_scope.Get_session) in
  let key = action_key ~epoch ~kind ~spec_hash in
  if Journal.has_fenced_done key then ()
  else begin
    Object_repository.put_fenced Object_repository.default ~hash:spec_hash spec;
    Journal.append (Journal.FencedIntent {
      key; epoch; kind; spec_hash });
    let result = run_command spec in
    Journal.append (Journal.FencedDone { key; result_hash = result_hash result })
  end

(* Execute a single unknown-status fenced action during recovery.  Uses the
   key/epoch/kind/spec-hash stored in the journal; loads the persisted spec by
   hash so the action runs with the same inputs. *)
let execute_recovery
    ~(decide : Journal.fenced_entry -> recovery_decision)
    ~(entry : Journal.fenced_entry) : unit =
  let result = match Object_repository.get_fenced Object_repository.default
      ~hash:entry.Journal.fe_spec_hash with
    | None ->
        (* A missing spec cannot be retried safely. *)
        VMap [(VString "aborted", VBool true);
              (VString "reason", VString "spec missing from store");
              (VString "kind", VString entry.Journal.fe_kind);
              (VString "spec-hash", VString entry.Journal.fe_spec_hash)]
    | Some spec ->
        (match decide entry with
         | Retry -> run_command spec
         | Abort ->
             VMap [(VString "aborted", VBool true);
                   (VString "kind", VString entry.Journal.fe_kind);
                   (VString "spec-hash", VString entry.Journal.fe_spec_hash)])
  in
  Journal.append (Journal.FencedDone {
    key = entry.Journal.fe_key; result_hash = result_hash result })

(* Resolve unknown-status actions from durable journal state. Recovery policy
   and prompting live at the command boundary; this module only executes the
   supplied decision and restores the recovered epoch for pass deduplication. *)
let recover_unknown
    ~(decide : Journal.fenced_entry -> recovery_decision) : int =
  let unknowns = Journal.pending_fenced_actions () in
  List.iter (fun entry ->
    execute_recovery ~decide ~entry;
    Session.resume_fenced_epoch (Effect.perform Dynamic_scope.Get_session) entry.Journal.fe_epoch) unknowns;
  List.length unknowns

(* Drain all fenced actions registered during this evaluation.  Called once
   per reconcile pass, after all convergent fs/proc work.  Uses an existing
   epoch when resuming a crashed pass (set by recover_unknown); otherwise
   generates a fresh epoch.  The epoch is cleared at the end so the next pass
   starts fresh. *)
let drain () : unit =
  ensure_epoch ();
  let actions = Session.take_fenced_actions (Effect.perform Dynamic_scope.Get_session) in
  List.iter (fun (kind, spec) -> execute_current ~kind ~spec) actions;
  Session.clear_fenced_epoch (Effect.perform Dynamic_scope.Get_session)
