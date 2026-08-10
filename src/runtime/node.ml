open Pp_kernel
(* node — the node-key skeleton and the one rebuilder. *)

open Core_model
open Source_error

module Key = Identity_types.Node_key
module Object_hash = Identity_types.Object_hash

let resolve_free_variables ~(expr : expr) ~(env : env)
    ~(force : value -> value) : (string * value option) list =
  Free_vars.SS.elements (Free_vars.node_free_vars expr)
  |> List.map (fun name ->
       match Environment.lookup env name with
       | Some value ->
           (try (name, Some (force value)) with
            | Error (Capability _) as error -> raise error
            | _ -> (name, Some value))
       | None -> (name, None))

let authorize_free_variables (free_variables : (string * value option) list) : unit =
  List.iter (fun (name, value) ->
    match value with
    | Some value when Value_analysis.contains_authority_in_referenced_values value ->
        authority_escape
          (Printf.sprintf
             "node: free variable '%s' may not be or contain a %s" name
             (if Value_analysis.contains_sealed value then
                "sealed value" else "capability"))
    | Some _ | None -> ())
    free_variables

let key_of ~(argument_values : value list) ~(expr : expr) ~(env : env)
    ~(force : value -> value) : Key.t =
  let free_variables = resolve_free_variables ~expr ~env ~force in
  authorize_free_variables free_variables;
  Identity.node_key ~code:expr ~free_variables ~argument_values


(* ---- Runtime type check (shared by the evaluator) --------------------- *)

let check_type (v : value) (ty : expr) (loc : Source_range.t option) : unit =
  let type_name =
    match ty with
    | ESymbol s -> s
    | ELiteral (VSymbol s) | ELiteral (VKeyword s) -> s
    | _ -> "unknown"
  in
  (* Known scalar type names. An unrecognized name (a typo, or a type pp does
     not check) deliberately falls through to [false] and reports a mismatch:
     an unknown type is a hard error, never a silent pass. *)
  let ok =
    match type_name with
    | "int" -> (match v with VInt _ -> true | _ -> false)
    | "float" -> (match v with VFloat _ -> true | _ -> false)
    | "string" -> (match v with VString _ -> true | _ -> false)
    | "bool" -> (match v with VBool _ -> true | _ -> false)
    | "nil" -> (match v with VNil -> true | _ -> false)
    | _ -> false
  in
  if not ok then
    (* Keep the annotation location separate from the message so an enclosing
       form boundary cannot duplicate it. *)
    eval ?location:loc
      (Printf.sprintf "type mismatch: expected %s, got %s"
              type_name (Presentation.string_of_value v))

(* Enforce a thunk's optional type annotation, resetting thunk_status to
   Unevaluated if the check fails. The reset is load-bearing: typed thunks are
   memoised by content hash (Evaluator.make_thunk_ca_typed), so a check_type
   that raised while the thunk was still `Evaluating` would leave it stuck, and
   the next force of the same thunk would misreport "infinite recursion"
   instead of the real type error (reproduced pre-fix by entering the same
   ill-typed `let (x: ty = ...)` form twice at the REPL). Callers invoke this
   after computing the body value and before marking the thunk Evaluated;
   shared by every typed-thunk path so the guard cannot drift. *)
let enforce_type (t : thunk) (result : value) : unit =
  match t.type_ann with
  | None -> ()
  | Some ty ->
      (try check_type result ty t.thunk_loc
       with e -> t.thunk_status <- Unevaluated; raise e)


(* ---- Serve hit / run node body (the rebuilder) ------------------------ *)

let serve_hit ~(t : thunk) (h : Cache_policy.result) : value option =
  match h with
  | Cache_policy.HitOk cached ->
      t.thunk_status <- Evaluated cached;
      Some cached
  | Cache_policy.HitFailed errval ->
      (match errval with
       | VString msg -> eval msg
       | _ -> eval "node failed (cached)")
  | Cache_policy.Miss -> None

let validate_result (t : thunk) (result : value) : unit =
  if Value_analysis.contains_authority result then begin
    t.thunk_status <- Unevaluated;
    if Value_analysis.contains_sealed result then
      authority_escape "a node may not return a sealed value"
    else
      authority_escape "a node may not return a capability"
  end;
  enforce_type t result

let persist ~(key : Key.t) ~(reads : (string * string) list)
    ~(outcome : Trace_repository.outcome) (result : value) : Object_hash.t =
  let cache_key = Identity_types.Cache_key.of_node_key key in
  let result_hash = Object_hash.of_digest (Identity.hash_value result) in
  Object_repository.put (Runtime_context.objects ())
    ~key:(Object_hash.to_string result_hash) ~value:result;
  Trace_repository.put (Runtime_context.traces ()) ~key:cache_key ~outcome ~result_hash
    ~reads:(List.map (fun (cell, hash) ->
      (Identity_types.Cell_id.of_string cell,
       Identity_types.Observed_hash.of_digest hash)) reads);
  result_hash

let persist_or_reset t ~key ~reads ~outcome result =
  try persist ~key ~reads ~outcome result with e ->
    t.thunk_status <- Unevaluated;
    raise e

let rebuild ~(key : Key.t) ~(run : unit -> value) (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let captured_caps = Evaluator_thunks.captured_capabilities t in
  let tail_depth = Dynamic_scope.tail_capability_depth () in
  let frame : (string * string) list ref = ref [] in
  let sandbox_slot = ref None in
  Fun.protect
    ~finally:(fun () -> match !sandbox_slot with Some d -> Sandbox.remove_tree d | None -> ())
    (fun () ->
      let result =
        try run ()
        with
        | effect Dynamic_scope.Get_capabilities, k ->
            let capabilities =
              match Dynamic_scope.tail_capabilities_at tail_depth with
              | Some capabilities -> capabilities
              | None -> captured_caps
            in
            Effect.Deep.continue k capabilities
        | effect (Dynamic_scope.Record_read (c, h)), k ->
            if not (List.mem (c, h) !frame) then frame := (c, h) :: !frame;
            Effect.Deep.continue k (Effect.perform (Dynamic_scope.Record_read (c, h)))
        | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k true
        | effect Dynamic_scope.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
        | Error error as e ->
            (match cache_decision error with
             | Cacheable ->
                 ignore (persist_or_reset t ~key ~reads:(List.rev !frame)
                   ~outcome:Trace_repository.Failed
                   (VString (string_of_t error)));
                 t.thunk_status <- Unevaluated;
                 raise e
             | Do_not_cache ->
                 t.thunk_status <- Unevaluated;
                 raise e)
        | Failure msg ->
            ignore (persist_or_reset t ~key ~reads:(List.rev !frame)
              ~outcome:Trace_repository.Failed (VString msg));
            t.thunk_status <- Unevaluated;
            raise (Error (Evaluator (diagnostic msg)))
        | e ->
            t.thunk_status <- Unevaluated;
            raise e
      in
      validate_result t result;
      let result_hash =
        try persist ~key ~reads:(List.rev !frame)
          ~outcome:Trace_repository.Ok result
        with e ->
          t.thunk_status <- Unevaluated;
          raise e
      in
      t.thunk_status <- Evaluated result;
      if Cache_policy.check_enabled (Runtime_context.cache ()) then begin
        let frame2 = ref [] in
        let r2 =
          try run ()
          with
          | effect (Dynamic_scope.Record_read (c, h)), k ->
              if not (List.mem (c, h) !frame2) then frame2 := (c, h) :: !frame2;
              Effect.Deep.continue k (Effect.perform (Dynamic_scope.Record_read (c, h)))
          | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k true
          | effect Dynamic_scope.Get_capabilities, k ->
              let capabilities =
                match Dynamic_scope.tail_capabilities_at tail_depth with
                | Some capabilities -> capabilities
                | None -> captured_caps
              in
              Effect.Deep.continue k capabilities
          | effect Dynamic_scope.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
          | e -> raise e
        in
        if Object_hash.of_digest (Identity.hash_value r2) <> result_hash then begin
          Cache_policy.note_volatile (Runtime_context.cache ());
          Printf.eprintf
            "[check] volatile node %s: an identical run produced a different result hash\n%!"
            (Cache_policy.short_key (Key.to_string key))
        end
      end;
      result)

let lookup_hit ~(key : Key.t) ~(authorized : Identity_types.Cell_id.t -> bool)
    (t : thunk) : value option =
  let cache_key = Identity_types.Cache_key.of_node_key key in
  serve_hit ~t (Cache_policy.lookup ((Runtime_context.cache ()))
    ~traces:(Runtime_context.traces ()) ~objects:(Runtime_context.objects ())
    ~blobs:(Runtime_context.blobs ()) ~observe_id:Observation.observe_id
    ~replay:Observation.replay
    ~key:cache_key ~authorized)
let force ~(key : Key.t) ~(authorized : Identity_types.Cell_id.t -> bool)
    ~(data_closed : bool) ~(run : unit -> value) (t : thunk) : value =
  Stabilize.register_node_key ~key ~thunk:t;
  let nested = Effect.perform Dynamic_scope.In_node in
  let run_force () =
    match lookup_hit ~key ~authorized t with
    | Some value -> value
    | None ->
        let scheduler = Session.scheduler (Effect.perform Dynamic_scope.Get_session) in
        let width = Scheduler.redundancy scheduler in
        if Scheduler.schedules_batches scheduler || width > 1 then
          let job = {
            Scheduler.j_key = key;
            j_width = width;
            j_data_closed = data_closed;
          } in
          Scheduler.dispatch_batch scheduler
            ~run:(fun _ -> ignore (rebuild ~key ~run t)) [job];
          (match lookup_hit ~key ~authorized t with
           | Some value -> value
           | None -> rebuild ~key ~run t)
        else rebuild ~key ~run t
  in
  let result =
    if not nested then run_force ()
    else
      try run_force () with
      | effect (Dynamic_scope.Record_read _), continuation ->
          Effect.Deep.continue continuation ()
  in
  if nested then
    Observation.record
      (Observation.node (Key.to_string key))
      (Identity.hash_value result);
  Option.iter (fun id ->
    Effect.perform (Dynamic_scope.Record_node_force id)) t.thunk_hash;
  result
