(* node — the node-key skeleton and the one rebuilder. *)

open Core_model
open Source_error


let fv_hash ~(name : string) (v : value) (force : value -> value) : string =
  match force v with
  | fv ->
      if Value_analysis.contains_authority fv then
        raise (Capability_error
          (Printf.sprintf
             "node: free variable '%s' may not be or contain a %s" name
             (if Value_analysis.contains_sealed fv then "sealed value" else "capability")));
      Hasher.hash_concat ["fv"; name; Identity.hash_value fv]
  | exception e ->
      (match e with
       | Capability_error _ -> raise e
       | _ -> Hasher.hash_concat ["fv"; name; Identity.hash_value v])

let unbound_fv_hash ~(name : string) : string =
  Hasher.hash_concat ["fv-unbound"; name]


(* ---- Runtime type check (shared by the evaluator) --------------------- *)

let check_type (v : value) (ty : expr) (loc : (string * int) option) : unit =
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
    (* The annotation site [loc] is a precise location, carried as Pp_error.pos
       (not baked into the message, which would double-locate once an enclosing
       form's with_form_location saw it). *)
    raise (Pp_error {
      kind = Eval;
      msg = Printf.sprintf "type mismatch: expected %s, got %s"
              type_name (Presentation.string_of_value v);
      pos = loc })

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


(* ---- Trace replay ----------------------------------------------------- *)

let replay_node_reads (t : thunk) (key_of : thunk -> string) : unit =
  if t.thunk_persist && Effect.perform Dynamic_scope.In_node then
    let traces = Trace_repository.load Trace_repository.default ~key:(key_of t) in
    List.iter (fun tr -> Observation.replay tr.Trace_repository.reads) traces


(* ---- Serve hit / run node body (the rebuilder) ------------------------ *)

let serve_hit ~(t : thunk) (h : Cache_policy.result) : value option =
  match h with
  | Cache_policy.HitOk cached ->
      t.thunk_status <- Evaluated cached;
      Some cached
  | Cache_policy.HitFailed errval ->
      (match errval with
       | VString msg -> failwith msg
       | _ -> failwith "node failed (cached)")
  | Cache_policy.Miss -> None

let run_node_body ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let frame = ref [] in
  let sandbox_slot = ref None in
  Fun.protect
    ~finally:(fun () -> match !sandbox_slot with Some d -> Sandbox.remove_tree d | None -> ())
    (fun () ->
      let result =
        try run ()
        with
        | effect Dynamic_scope.Get_capabilities, k -> Effect.Deep.continue k t.node_caps
        | effect (Dynamic_scope.Record_read (c, h)), k ->
            if not (List.mem (c, h) !frame) then frame := (c, h) :: !frame;
            Effect.Deep.continue k (Effect.perform (Dynamic_scope.Record_read (c, h)))
        | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k true
        | effect Dynamic_scope.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
        (* Memoize a genuine failure (LAW 28). A plain Failure, or an Eval-kind
           Pp_error a nested `load`'s form boundary already wrapped, is
           cacheable; a Capability error (raw or Pp_error kind=Capability) is
           NOT (LAW 15) and falls to the generic reset arm below. *)
        | (Failure msg | Pp_error { kind = Eval; msg; _ }) as e ->
            let errval = VString msg in
            let err_hash = Identity.hash_value errval in
            (try Object_repository.put Object_repository.default ~key:err_hash ~value:errval with _ -> ());
            (try Trace_repository.put Trace_repository.default ~key ~outcome:Trace_repository.Failed ~result_hash:err_hash
                   ~reads:(List.rev !frame) with _ -> ());
            t.thunk_status <- Unevaluated;
            raise e
        | e ->
            t.thunk_status <- Unevaluated;
            raise e
      in
      if Value_analysis.contains_authority result then begin
        t.thunk_status <- Unevaluated;
        if Value_analysis.contains_sealed result then
          raise (Capability_error "a node may not return a sealed value")
        else
          raise (Capability_error "a node may not return a capability")
      end;
      enforce_type t result;
      t.thunk_status <- Evaluated result;
      let result_hash = Identity.hash_value result in
      (try Object_repository.put Object_repository.default ~key:result_hash ~value:result with _ -> ());
      (try Trace_repository.put Trace_repository.default ~key ~outcome:Trace_repository.Ok ~result_hash
             ~reads:(List.rev !frame) with _ -> ());
      if Cache_policy.check_enabled Cache_policy.default then begin
        let frame2 = ref [] in
        let r2 =
          try run ()
          with
          | effect (Dynamic_scope.Record_read (c, h)), k ->
              if not (List.mem (c, h) !frame2) then frame2 := (c, h) :: !frame2;
              Effect.Deep.continue k (Effect.perform (Dynamic_scope.Record_read (c, h)))
          | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k true
          | effect Dynamic_scope.Get_capabilities, k -> Effect.Deep.continue k t.node_caps
          | effect Dynamic_scope.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
          | e -> raise e
        in
        if Identity.hash_value r2 <> result_hash then begin
          Cache_policy.note_volatile Cache_policy.default;
          Printf.eprintf
            "[check] volatile node %s: an identical run produced a different result hash\n%!"
            (Cache_policy.short_key key)
        end
      end;
      result)
