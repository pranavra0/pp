(* node — the node-key skeleton and the one rebuilder. *)

open Types

let node_key_skeleton ~(expr_hash : string) (fv_hashes : string list) : string =
  hash_concat (["node-key"; expr_hash] @ fv_hashes)

let fv_hash ~(name : string) (v : value) (force : value -> value) : string =
  match force v with
  | fv ->
      if contains_authority fv then
        raise (Capability_error
          (Printf.sprintf
             "node: free variable '%s' may not be or contain a %s" name
             (if contains_sealed fv then "sealed value" else "capability")));
      hash_concat ["fv"; name; hash_value fv]
  | exception e ->
      (match e with
       | Capability_error _ -> raise e
       | _ -> hash_concat ["fv"; name; hash_value v])

let unbound_fv_hash ~(name : string) : string =
  hash_concat ["fv-unbound"; name]


(* ---- Runtime type check (shared by both backends) --------------------- *)

let check_type (v : value) (ty : expr) (loc : (string * int) option) : unit =
  let type_name =
    match ty with
    | ESymbol s -> s
    | ELiteral (VSymbol s) | ELiteral (VKeyword s) -> s
    | _ -> "unknown"
  in
  let ok =
    match type_name with
    | "int" -> (match v with VInt _ -> true | _ -> false)
    | "string" -> (match v with VString _ -> true | _ -> false)
    | "bool" -> (match v with VBool _ -> true | _ -> false)
    | "nil" -> (match v with VNil -> true | _ -> false)
    | _ -> false
  in
  if not ok then
    let loc_str = match loc with
      | Some (file, line) -> Printf.sprintf " at %s:%d" file line
      | None -> ""
    in
    failwith (Printf.sprintf "type mismatch: expected %s, got %s%s"
                type_name (string_of_value v) loc_str)


(* ---- Trace replay ----------------------------------------------------- *)

let replay_node_reads (t : thunk) (key_of : thunk -> string) : unit =
  if t.thunk_persist && Effect.perform Runtime.In_node then
    let traces = Store.load_traces ~key:(key_of t) in
    List.iter (fun tr ->
      List.iter (fun (c, h) -> Runtime.record_read c h) tr.Store.tr_reads
    ) traces


(* ---- Serve hit / run node body (the rebuilder) ------------------------ *)

let serve_hit ~(t : thunk) (h : Store.hit_result) : value option =
  match h with
  | Store.HitOk cached ->
      t.thunk_status <- Evaluated cached;
      Some cached
  | Store.HitFailed errval ->
      (match errval with
       | VString msg -> failwith msg
       | _ -> failwith "node failed (cached)")
  | Store.Miss -> None

let run_node_body ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let frame = ref [] in
  let sandbox_slot = ref None in
  Fun.protect
    ~finally:(fun () -> match !sandbox_slot with Some d -> Runtime.remove_tree d | None -> ())
    (fun () ->
      let result =
        try run ()
        with
        | effect Runtime.Get_capabilities, k -> Effect.Deep.continue k t.node_caps
        | effect (Runtime.Record_read (c, h)), k ->
            if not (List.mem (c, h) !frame) then frame := (c, h) :: !frame;
            Effect.Deep.continue k (Effect.perform (Runtime.Record_read (c, h)))
        | effect Runtime.In_node, k -> Effect.Deep.continue k true
        | effect Runtime.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
        | Failure msg as e ->
            let errval = VString msg in
            let err_hash = hash_value errval in
            (try Store.store_object ~key:err_hash ~value:errval with _ -> ());
            (try Store.store_trace ~key ~outcome:Store.Failed ~result_hash:err_hash
                   ~reads:(List.rev !frame) with _ -> ());
            t.thunk_status <- Unevaluated;
            raise e
        | e ->
            t.thunk_status <- Unevaluated;
            raise e
      in
      if contains_authority result then begin
        t.thunk_status <- Unevaluated;
        if contains_sealed result then
          raise (Capability_error "a node may not return a sealed value")
        else
          raise (Capability_error "a node may not return a capability")
      end;
      (match t.type_ann with
       | Some ty -> check_type result ty t.thunk_loc
       | None -> ());
      t.thunk_status <- Evaluated result;
      let result_hash = hash_value result in
      (try Store.store_object ~key:result_hash ~value:result with _ -> ());
      (try Store.store_trace ~key ~outcome:Store.Ok ~result_hash
             ~reads:(List.rev !frame) with _ -> ());
      if !Store.check_mode then begin
        let frame2 = ref [] in
        let r2 =
          try run ()
          with
          | effect (Runtime.Record_read (c, h)), k ->
              if not (List.mem (c, h) !frame2) then frame2 := (c, h) :: !frame2;
              Effect.Deep.continue k (Effect.perform (Runtime.Record_read (c, h)))
          | effect Runtime.In_node, k -> Effect.Deep.continue k true
          | effect Runtime.Get_capabilities, k -> Effect.Deep.continue k t.node_caps
          | effect Runtime.Current_sandbox, k -> Effect.Deep.continue k (Some sandbox_slot)
          | e -> raise e
        in
        if hash_value r2 <> result_hash then begin
          incr Store.volatile_count;
          Printf.eprintf
            "[check] volatile node %s: an identical run produced a different result hash\n%!"
            (Store.short_key key)
        end
      end;
      result)