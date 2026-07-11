(* pp evaluator — lazy, call-by-need evaluator with thunks *)

open Types
open Hasher
open Runtime

(* ---- Evaluation State ---- *)

(* Content-addressed thunk store is now in Runtime. *)

(* Create or retrieve a content-addressed thunk.
   Two thunks with the same (expr, env, capabilities) are the SAME thunk.
   Uses env.env_hash for O(1) environment identity — no recursive traversal. *)
let make_thunk_ca (expr : expr) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
  let h = hash_concat ["thunk"; Hasher.hash_expr expr; env.env_hash; caps_hash; cfg_hash; handlers_hash ()] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = None; thunk_loc = None; config_hash = cfg_hash; thunk_persist = false; node_fv = [] } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Like make_thunk_ca, but the thunk carries a type annotation that is
   checked when the thunk is forced (mirrors the VM's MAKE_THUNK with
   type_ann, vm.ml). The annotation participates in the content hash so a
   typed thunk is never conflated with an untyped thunk over the same expr. *)
let make_thunk_ca_typed (expr : expr) (ty : expr) (loc : (string * int) option) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
  let h = hash_concat ["thunk-typed"; Hasher.hash_expr expr; Hasher.hash_expr ty; env.env_hash; caps_hash; cfg_hash; handlers_hash ()] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = Some ty; thunk_loc = loc; config_hash = cfg_hash; thunk_persist = false; node_fv = [] } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Runtime check for gradual type annotations. Shared by both backends (the
   VM calls it too), so they fail identically by construction. *)
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
    | _ -> true  (* unknown types pass for v1 *)
  in
  if not ok then
    let loc_str = match loc with
      | Some (file, line) -> Printf.sprintf " at %s:%d" file line
      | None -> "" in
    failwith (Printf.sprintf "type mismatch: expected %s, got %s%s"
                type_name (string_of_value v) loc_str)

(* LAW 23b: whether the caller's current capabilities permit reading a trace
   cell. Used to gate cache hits on the transitive read closure. The match is
   exhaustive over Cell.t so adding a cell kind forces an authority decision
   here. *)
let cell_authorized (cell_id : string) : bool =
  let has_fs_read path =
    List.exists (fun cap -> Capabilities.check_fs_read cap path) !current_capabilities
  in
  match Cell.of_string cell_id with
  | Cell.File path -> has_fs_read path
  (* A coarse tree observation (run effect, Q2) is covered by an fs-read
     grant over the root. *)
  | Cell.Tree root -> has_fs_read root
  (* A tool observation came from a `run`; serving a result that embeds
     one requires process authority, not an fs grant over the binary. *)
  | Cell.Tool _ ->
      List.exists (function CapProcess -> true | _ -> false) !current_capabilities
  (* A file-predicate observation (file-exists?/dir?) discloses presence,
     so serving it requires the same fs-read authority as recording it. *)
  | Cell.Stat path -> has_fs_read path
  (* No user authority attaches: config/handler are ambient (LAW 33/26),
     runtime:file loader reads ran under interpreter authority (Q6/D8c),
     env/argv/proc are program-level inputs. Unknown cells never verify, so
     authorizing them is moot. *)
  | Cell.RuntimeFile _ | Cell.Env _ | Cell.Argv
  | Cell.Config _ | Cell.Handler _ | Cell.Proc _ | Cell.Unknown _ -> true

(* Trace replay for an already-Evaluated persistent node: replay its stored
   trace reads into the active trace frames so the caller's trace transitively
   captures this node's world-reads (same mechanism as Store.hit's hit-replay).
   [key_of] is the backend's node-key function (node_key_of / vm_node_key). *)
let replay_node_reads (t : thunk) (key_of : thunk -> string) : unit =
  if t.thunk_persist && !Runtime.trace_stack <> [] then
    let traces = Store.load_traces ~key:(key_of t) in
    List.iter (fun tr ->
      List.iter (fun (c, h) -> Runtime.record_read c h) tr.Store.tr_reads
    ) traces

(* Run a persistent node's body and store the result (LAW 21) or the failure
   (LAW 28) with its verifying trace. Shared by the tree-walker's force, the
   trampoline, and the VM's force_node_thunk — the node caches identically
   however it is demanded. [run] executes the body; the caller owns any
   backend-specific bookkeeping (force_depth, operand-stack isolation). *)
let run_node_body ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  t.thunk_status <- Evaluating;
  (* The trace frame captures the world-reads (slurp, read-file, …) this node
     makes as (cell-id, observed-hash) pairs. Popped on every exit — normal or
     exceptional — so a raised error never leaks a dangling frame. *)
  let frame = Runtime.push_trace_frame () in
  let result =
    try
      let r = run () in
      Runtime.pop_trace_frame ();
      r
    with
    | Failure msg as e ->
        Runtime.pop_trace_frame ();
        (* LAW 28: store a FAILING trace — the error value plus the reads made
           up to the failure — so a re-force with unchanged inputs re-serves the
           failure, and re-runs only when a read changes. D16: reset the status
           off `Evaluating` so the next force reports the real error, not a fake
           "infinite recursion". A Capability_error is not a Failure and is
           never memoized (LAW 15/20). *)
        let errval = VString msg in
        let err_hash = Hasher.hash_value errval in
        (try Store.store_object ~key:err_hash ~value:errval with _ -> ());
        (try Store.store_trace ~key ~outcome:Failed ~result_hash:err_hash
               ~reads:(List.rev !frame) with _ -> ());
        t.thunk_status <- Unevaluated;
        raise e
    | e ->
        Runtime.pop_trace_frame ();
        t.thunk_status <- Unevaluated;
        raise e
  in
  (match t.type_ann with
   | Some ty -> check_type result ty t.thunk_loc
   | None -> ());
  t.thunk_status <- Evaluated result;
  let result_hash = Hasher.hash_value result in
  (* Objects are content-addressed by result hash; the trace maps the node
     key to that result plus the reads that justify it. *)
  (try Store.store_object ~key:result_hash ~value:result with _ -> ());
  (try Store.store_trace ~key ~outcome:Ok ~result_hash
         ~reads:(List.rev !frame) with _ -> ());
  (* --check (LAW 38): run the body a second time under a throwaway trace
     frame; a different result hash means the node observed something no
     cell captured — volatile, and unsafe to cache. *)
  if !Store.check_mode then begin
    ignore (Runtime.push_trace_frame ());
    let r2 =
      try run ()
      with e -> Runtime.pop_trace_frame (); raise e
    in
    Runtime.pop_trace_frame ();
    if Hasher.hash_value r2 <> result_hash then begin
      incr Store.volatile_count;
      Printf.eprintf
        "[check] volatile node %s: an identical run produced a different result hash\n%!"
        (Store.short_key key)
    end
  end;
  result

(* Force a persistent node through the store: serve a verified hit (gated on
   the caller's authority over the trace's read closure, LAW 23b), re-serve a
   memoized failure (LAW 28), or run and store on a miss. *)
let force_node ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  Stabilize.register_node_key ~key ~thunk:t;
  match Store.hit ~key ~authorized:cell_authorized with
  | Store.HitOk cached ->
      t.thunk_status <- Evaluated cached;
      cached
  | Store.HitFailed errval ->
      (match errval with
       | VString msg -> failwith msg
       | _ -> failwith "node failed (cached)")
  | Store.Miss -> run_node_body ~key ~run t

(* Module exports: the bindings of [bindings] not present in [base]
   (insertion order preserved). With [dedup], each name is exported once —
   newest binding wins (a value def's backpatched poison pre-binding must not
   shadow the real binding). *)
let new_bindings ?(dedup = false) ~(base : (string * value) list)
    (bindings : (string * value) list) : (string * value) list =
  let rec collect all acc =
    match all with
    | [] -> List.rev acc
    | (n, v) :: rest ->
        if List.exists (fun (pn, _) -> pn = n) base
           || (dedup && List.exists (fun (an, _) -> an = n) acc) then
          collect rest acc
        else
          collect rest ((n, v) :: acc)
  in
  collect bindings []

(* letrec* poison for value defs in blocks: a fresh (non-content-addressed)
   thunk pre-bound at block entry so the whole block sees the binding; forcing
   it before the def executes raises, and the def backpatches it in place. The
   error expression compiles/evaluates to the SAME text in both backends. *)
let poison_expr (name : string) : expr =
  EApply (ESymbol "error",
          [ELiteral (VString (name ^ ": referenced before its definition"))])

let poison_thunk (name : string) (env : env) : value =
  make_thunk (poison_expr name) env

(* ---- Force: evaluate a thunk on demand ---- *)

(* Depth limit before switching to heap-allocated trampoline.
   OCaml's default stack handles ~10k small frames; 2000 gives
   ample headroom while keeping the trampoline nesting shallow
   even for 10^6-deep recursion (~500 trampoline entries). *)
let max_force_depth = 2000
let force_depth = ref 0



(* Main force entry-point: uses native stack for shallow chains,
   switches to trampoline when depth exceeds threshold. *)
let rec force (v : value) : value =
  incr force_depth;
  match v with
  | _ when !force_depth > max_force_depth ->
      let saved = !force_depth in
      force_depth := 0;
      let r = trampoline_force v in
      force_depth := saved;
      decr force_depth;
      r
  | VThunk t ->
      (match t.thunk_status with
       | Evaluated result ->
           decr force_depth;
           replay_node_reads t node_key_of;
           force result
       | Evaluating ->
           decr force_depth;
           failwith "infinite recursion detected (forcing a thunk already being evaluated)"
       | Unevaluated ->
           (* Persistent nodes route through the store. Identity is the
              LAW 20 node key (code + free-var value hashes); the trace decides
              validity. A stale trace falls through to recompute. *)
           if t.thunk_persist then
             let nk = node_key_of t in
             let run () =
               match t.vm_code with
               | Some (bc, code_offset, frames) ->
                   !Primitives.vm_run_thunk_ref bc code_offset frames
               | None ->
                   eval t.thunk_expr t.thunk_env
             in
             (match force_node ~key:nk ~run t with
              | result -> decr force_depth; force result
              | exception e -> decr force_depth; raise e)
           else
             evaluate_and_store_no_key t)
  | _ ->
      decr force_depth;
      v

and evaluate_and_store_no_key (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let result =
    try
      match t.vm_code with
      | Some (bc, code_offset, frames) ->
          !Primitives.vm_run_thunk_ref bc code_offset frames
      | None ->
          eval t.thunk_expr t.thunk_env
    with e ->
      (* D16: an ephemeral thunk that raised must not be left `Evaluating`, or
         the next force misreports "infinite recursion". Reset and re-raise the
         real error (ephemeral thunks are not failure-cached). *)
      t.thunk_status <- Unevaluated;
      decr force_depth;
      raise e
  in
  (match t.type_ann with
   | Some ty -> check_type result ty t.thunk_loc
   | None -> ());
  t.thunk_status <- Evaluated result;
  decr force_depth;
  force result

(* LAW 20: a node's persistent key is its code structure plus the *value* hashes
   of the free variables it references (forced, call-by-value — the key cannot
   exist before its inputs' values do). This deliberately omits the whole-env
   hash (so rebinding an unrelated global does not re-key the node), the
   capability set (authority gates *access* to a hit — LAW 23 — never identity),
   and the ambient config/handler stacks: a config value or handler the node
   actually observed is recorded in its trace as a `config:`/`handler:` cell
   and governs validity, not identity (LAW 33/26). *)
and node_key_of (t : thunk) : string =
  let e = t.thunk_expr in
  let fv_parts =
    Types.SS.elements (Types.free_vars e)
    |> List.map (fun name ->
         match lookup_env t.thunk_env name with
         | Some v ->
             let hv = (try Hasher.hash_value (force v)
                       with _ -> Hasher.hash_value v) in
             hash_concat ["fv"; name; hv]
         | None -> hash_concat ["fv-unbound"; name])
  in
  hash_concat (["node-key"; Hasher.hash_expr e] @ fv_parts)

(* ---- Main Evaluator (non-tail) ---- *)

and eval (e : expr) (env : env) : value =
  Primitives.current_env_ref := env;
  eval_tail e env (fun v -> v)

(* ---- Tail-position evaluator ---- *)
(* eval_tail e env k: evaluates e in tail position with continuation k.
   The continuation k is threaded through tail calls without growing the
   OCaml stack — this is how TCO works. *)

and eval_tail (e : expr) (env : env) (k : value -> value) : value =
  Primitives.current_env_ref := env;
  match e with
  | ELiteral v -> k v

  | ESymbol name ->
      (match lookup_env env name with
       | Some v -> k (force v)
       | None ->
           (match Primitives.lookup name with
            | Some v -> k v
            | None -> failwith ("unbound symbol: " ^ name)))

  | EIf (cond, then_e, else_e) ->
      (* Condition is non-tail; branches are tail *)
      (match force (eval cond env) with
       | VBool true -> eval_tail then_e env k
       | VBool false -> eval_tail else_e env k
       | VNil -> eval_tail else_e env k
       | _ -> eval_tail then_e env k)

  | ELet (bindings, body) ->
      (* Mutual let: all bindings visible in every RHS (LAW 1).
         Create thunks with outer env, build mutual env, then backpatch
         each thunk's env so they see each other when forced. *)
      let thunks = List.map (fun (name, binding_expr) ->
        (name, make_thunk_ca binding_expr env)
      ) bindings in
      let env_mutual = List.fold_left (fun e (name, thunk) ->
        extend_env e name thunk
      ) env thunks in
      List.iter (fun (_, thunk) ->
        match thunk with
        | VThunk t -> t.thunk_env <- env_mutual
        | _ -> ()
      ) thunks;
      eval_tail body env_mutual k

  | EFn (params, body) ->
      k (make_closure ~name:None params body (ref env))

  | EApply (fn_expr, arg_exprs) ->
      (* Strict application (Q1): force fn and all args before calling.
         This is call-by-value: arguments are evaluated before the body runs. *)
      let fn_val = force (eval fn_expr env) in
      let arg_vals = List.map (fun arg_expr -> force (eval arg_expr env)) arg_exprs in
      apply_tail fn_val arg_vals env k

  | EQuote e ->
      k (Types.quote_to_value e)

  | EForce e ->
      (* EForce in tail position: eval the inner expression in tail position,
         then force the result and pass to k *)
      eval_tail e env (fun v -> k (force v))

  | EDelay e ->
      k (make_thunk_ca e env)

  | ENode e ->
      let thunk_val = make_thunk_ca e env in
      (match thunk_val with VThunk t -> t.thunk_persist <- true | _ -> ());
      k thunk_val

  | EDefNode (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

  | EDo exprs ->
      (* All but last are non-tail; last is tail.
         Uses a local env ref for threading — NOT current_env_ref,
         because inner evaluations would clobber it. *)
      let env_ref = ref env in
      (* letrec* prologue: pre-bind every value def to a poison thunk so the
         whole block sees the binding (LAW 4); its def backpatches it. *)
      let poisons : (string, value) Hashtbl.t = Hashtbl.create 4 in
      List.iter (function
        | EDefValue (name, _) ->
            let p = poison_thunk name !env_ref in
            Hashtbl.replace poisons name p;
            env_ref := extend_env !env_ref name p
        | _ -> ()) exprs;
      let rec go = function
        | [] -> k VNil
        | [last] -> eval_tail last !env_ref k
        | (EDef (name, params, body)) :: rest ->
            let closure = make_closure ~name:(Some name) params body env_ref in
            env_ref := extend_env !env_ref name closure;
            go rest
        | (EDefNode (name, params, body)) :: rest ->
            let closure = make_closure ~name:(Some name) params body env_ref in
            env_ref := extend_env !env_ref name closure;
            go rest
        | (EDefValue (name, rhs)) :: rest ->
            let v = eval rhs !env_ref in
            (match Hashtbl.find_opt poisons name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            env_ref := extend_env !env_ref name v;
            go rest
        | (EImport mod_expr) :: rest ->
            let mod_val = force (eval mod_expr !env_ref) in
            (match mod_val with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> failwith "import expects a module value")
        | (ELoad path) :: rest ->
            let source = Runtime.loader_read path in
            let exprs = Reader.read_string source in
            ignore (eval_expressions exprs env_ref);
            go rest
        | (ELoadModule path) :: rest ->
            (match eval_module_file path with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
        | e :: rest ->
            let result = force (eval e !env_ref) in
            (match result with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
      in
      go exprs

  | EEffect (caps_expr, body) ->
      let caps_val = force (eval caps_expr env) in
      let caps =
        match caps_val with
        | VNil -> []
        | _ -> extract_capabilities caps_val
      in
      with_ref current_capabilities (caps @ !current_capabilities)
        (fun () -> eval_tail body env k)

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      k (perform_effect name forced_args)

  | EWithHandler (handlers, body) ->
      let new_handlers = List.map (fun (name, handler_expr) ->
        let handler_val = force (eval handler_expr env) in
        (name,
         (fun args -> apply handler_val args env),
         hash_value handler_val)   (* D17: handler identity in the key *)
      ) handlers in
      with_ref handler_stack (new_handlers @ !handler_stack)
        (fun () -> eval_tail body env k)

  | EDef (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

  | EDefValue (_, rhs) ->
      (* Bare expression position: evaluate the RHS and return it; binding is
         the job of the enclosing block / top level (mirrors EDef, which
         returns its closure without binding here). *)
      k (eval rhs env)

  | ELetStar (bindings, body) ->
      let rec nest env' = function
        | [] -> eval_tail body env' k
        | (name, expr) :: rest ->
            let thunk = make_thunk_ca expr env' in
            let env'' = extend_env env' name thunk in
            nest env'' rest
      in
      nest env bindings

  | EModule body_exprs ->
      let base_env = Primitives.initial_env () in
      let mod_env = ref base_env in
      (* letrec* prologue for value defs, as in EDo. *)
      let poisons : (string, value) Hashtbl.t = Hashtbl.create 4 in
      let prebound_env = List.fold_left (fun acc e ->
        match e with
        | EDefValue (name, _) ->
            let p = poison_thunk name acc in
            Hashtbl.replace poisons name p;
            extend_env acc name p
        | _ -> acc) !mod_env body_exprs in
      mod_env := prebound_env;
      let final_env = List.fold_left (fun (env_acc : env) e ->
        match e with
        | EDef (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefNode (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefValue (def_name, rhs) ->
            let v = eval rhs env_acc in
            (match Hashtbl.find_opt poisons def_name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            extend_env env_acc def_name v
        | EImport mod_expr ->
            let mod_val = force (eval mod_expr env_acc) in
            (match mod_val with
             | VEnvMap bindings ->
                 List.fold_left (fun e (n, v) -> extend_env e n v) env_acc bindings
             | _ -> failwith "import within module expects a module value")
        | _ ->
            ignore (force (eval e env_acc));
            env_acc
      ) !mod_env body_exprs in
      k (VEnvMap (new_bindings ~dedup:true ~base:base_env.bindings final_env.bindings))

  | EImport mod_expr ->
      let mod_val = force (eval mod_expr env) in
      k mod_val

  | ELoad path ->
      let source = Runtime.loader_read path in
      let exprs = Reader.read_string source in
      let env_ref = ref env in
      k (eval_expressions exprs env_ref)

  | ELoadModule path ->
      k (eval_module_file path)

  | ELocated (loc, ETyped (e, ty)) ->
      (* Mirror the compiler (compiler.ml ELocated+ETyped): a located
         annotation becomes a typed thunk carrying the location. *)
      k (make_thunk_ca_typed e ty (Some loc) env)
  | ELocated (_, e) -> eval_tail e env k
  | ETyped (e, ty) ->
      (* Type annotations defer evaluation into a thunk whose result is
         checked at force time — same semantics as the VM (compiler.ml
         emit_thunk_region + vm.ml FORCE/check_type). *)
      k (make_thunk_ca_typed e ty None env)
  | EIsland (uri, pin) ->
      (* D2: resolve the inline pin to the immutable cached tree (verified
         against the pin on every resolve), then evaluate its entry.pp as a
         module. The pin is part of this expression's hash, so island
         identity is structural (LAW 20) — no trace cell. *)
      let tree = Island.resolve ~uri ~pin in
      k (eval_module_file (Island.entry_file tree))
  | EWithConfig (map_expr, body) ->
      let cfg = force (eval map_expr env) in
      (match cfg with
       | VMap _ ->
           with_ref config_stack (cfg :: !config_stack)
             (fun () -> eval_tail body env k)
       | _ -> failwith "with-config expects a map")
  | EConfig (key_expr, default_opt) ->
      let key_val = force (eval key_expr env) in
      let key_name = match key_val with
        | VString s | VKeyword s | VSymbol s -> s
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      (* LAW 33: reading config inside a node is an observation — recorded as a
         `config:<key>` trace cell (absence included), never part of the key. *)
      Runtime.record_config_read key_name;
      (match Runtime.config_lookup key_name with
       | Some v -> k v
       | None ->
           (match default_opt with
            | Some d -> eval_tail d env k
            | None -> k VNil))

(* ---- Function Application (non-tail) ---- *)

and apply (fn : value) (args : value list) (env : env) : value =
  apply_tail fn args env (fun v -> v)

(* ---- Tail-position application ---- *)
(* apply_tail fn args env k: applies fn to args, evaluates the body in
   tail position with continuation k. This is the engine of TCO: the
   continuation k is passed through to eval_tail on the function body,
   so a tail-call chain never grows the OCaml stack. *)

and apply_tail (fn : value) (args : value list) (env : env) (k : value -> value) : value =
  match fn with
  | VClosure { fn_name; params; body; env = closure_env; _ } ->
      if List.length params <> List.length args then begin
        let fname = match fn_name with Some n -> n | None -> "#<fn>" in
        failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d"
                    fname (List.length params) (List.length args))
      end;
      let env' = List.fold_left2 (fun e param arg ->
        extend_env e param arg  (* arg is already a thunk *)
      ) !closure_env params args in
      eval_tail body env' k

  | VBuiltin (_, f) ->
      (* No re-wrapping of the error text: primitives name themselves in their
         own messages, and the VM calls builtins unwrapped — wrapping here made
         the two backends' error output differ (and mangled user `error`
         messages into "builtin 'error' failed: …"). *)
      Primitives.current_env_ref := env;
      k (f args)

  | _ ->
      failwith (Printf.sprintf "not a function: %s" (string_of_value fn))


(* Trampoline force: uses a local work queue to process thunk chains
   without growing the OCaml stack.  Only entered when [force_depth]
   exceeds [max_force_depth].  Part of the mutual-recursion block
   so it can reference [eval] and [force]. *)
and trampoline_force (v : value) : value =
  let queue = Queue.create () in
  Queue.add v queue;
  let rec loop () =
    match Queue.take_opt queue with
    | None -> failwith "trampoline: empty queue"
    | Some v ->
        begin match v with
        | VThunk t ->
            begin match t.thunk_status with
            | Evaluated result -> Queue.add result queue; loop ()
            | Evaluating -> failwith "infinite recursion detected (trampoline)"
            | Unevaluated ->
                if t.thunk_persist then begin
                  let h = node_key_of t in
                  let run () =
                    match t.vm_code with
                    | Some (bc, code_offset, frames) ->
                        !Primitives.vm_run_thunk_ref bc code_offset frames
                    | None ->
                        let saved = !force_depth in
                        force_depth := 0;
                        let r = eval t.thunk_expr t.thunk_env in
                        force_depth := saved;
                        r
                  in
                  let result = force_node ~key:h ~run t in
                  Queue.add result queue;
                  loop ()
                end
                else begin
                  (* ephemeral thunk — no store check *)
                  t.thunk_status <- Evaluating;
                  let result =
                    match t.vm_code with
                    | Some (bc, code_offset, frames) ->
                        !Primitives.vm_run_thunk_ref bc code_offset frames
                    | None ->
                        let saved = !force_depth in
                        force_depth := 0;
                        let r = eval t.thunk_expr t.thunk_env in
                        force_depth := saved;
                        r
                  in
                  (match t.type_ann with
                   | Some ty -> check_type result ty t.thunk_loc
                   | None -> ());
                  t.thunk_status <- Evaluated result;
                  Queue.add result queue;
                  loop ()
                end
            end
        | _ -> v  (* non-thunk: done *)
        end
  in
  loop ()
(* ---- Effect System ---- *)

and perform_effect (name : string) (args : value list) : value =
  (* LAW 26: WHICH handler intercepts this effect (or that none does — the
     builtin) is an observation of ambient state; inside a node it is recorded
     as a `handler:<effect>` trace cell so a hit under a different handler
     (mock vs real) re-computes instead of cross-contaminating. *)
  Runtime.record_handler_observation name;
  (* Check for handler *)
  let rec find_handler = function
    | [] ->
        (* No handler — try builtin effect *)
        perform_builtin_effect name args
    | (n, handler, _) :: rest ->
        if n = name then handler args
        else find_handler rest
  in
  find_handler !handler_stack

and perform_builtin_effect (name : string) (args : value list) : value =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           (* Node-local sandbox scratch reads are capability-free and
              unrecorded (LAW 18) — scratch is the node's working memory. *)
           (match Process.sandbox_read path with
            | Some content -> VString content
            | None ->
              if not (has_fs_read path) then
                raise (Capability_error ("read-file: capability error: no read access for " ^ path));
              (* Cell observation: recorded + CAS-pinned in node context (Q11). *)
              (try VString (Store.read_file_cell path)
               with Sys_error msg -> failwith ("read-file: " ^ msg)))
       | _ -> failwith "read-file expects a string path")

  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           (* LAW 18: inside a node, relative ⇒ sandbox scratch, absolute ⇒
              error; scripting tier unchanged (Process.write_file_effect). *)
           Process.write_file_effect ~has_cap:has_fs_write path content
       | _ -> failwith "write-file expects path and content strings")

  | "run" ->
      (* D13: process execution — capability-gated, trace-recorded, sandboxed
         (process.ml). *)
      Process.run_effect args

  | "run-dep" ->
      (* Q2 refinement: run + depfile → precise cells, no coarse tree cells. *)
      Process.run_dep_effect args

  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg;
           VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg;
           VNil
       | _ -> failwith "log expects a message string")

  | _ ->
      failwith ("unhandled effect: " ^ name)

(* ---- Helpers ---- *)

and has_fs_read (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_read cap path) !current_capabilities

and has_fs_write (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_write cap path) !current_capabilities

and extract_capabilities (v : value) : capability list =
  (* Forces via the registered force (Primitives.force_val) so the active
     backend forces its own thunks — this function is shared with the VM's
     ENTER_EFFECT. *)
  match v with
  | VCapability c -> [c]
  | VVector vs -> Array.to_list (Array.map (fun v ->
      match Primitives.force_val v with VCapability c -> c | _ -> failwith "capability vector must contain capabilities"
    ) vs)
  | VPair _ ->
      let rec collect acc = function
        | VNil -> List.rev acc
        | VPair (v, rest) ->
            (match Primitives.force_val v with
             | VCapability c -> collect (c :: acc) rest
             | other -> failwith ("not a capability: " ^ string_of_value other))
        | _ -> failwith "capability list must be a proper list"
      in
      collect [] v
  | _ -> failwith ("expected capability, got: " ^ string_of_value v)


(* (load-module "file.pp"): evaluate the file against a fresh initial env and
   package the bindings it added as a module value. Shared by the tail
   evaluator and EDo. *)
and eval_module_file (path : string) : value =
  let source = Runtime.loader_read path in
  let exprs = Reader.read_string source in
  let mod_ref = ref (Primitives.initial_env ()) in
  ignore (eval_expressions exprs mod_ref);
  VEnvMap (new_bindings ~base:(Primitives.initial_env ()).bindings (!mod_ref).bindings)

(* Evaluate expressions sequentially with mutable env — used by ELoad, ELoadModule, and REPL *)
and eval_expressions (exprs : expr list) (env : env ref) : value =
  let unwrap e = match e with ELocated (_, e') -> e' | _ -> e in
  let rec go = function
    | [] -> VNil
    | [e] ->
        (match unwrap e with
         | EDef (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             closure
         | EDefNode (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             closure
         | EDefValue (name, rhs) ->
             (* Top level is sequential: the RHS is evaluated now (a forward
                reference is an unbound-symbol error), the value bound. *)
             let v = eval rhs !env in
             env := extend_env !env name v;
             v
         | EImport mod_expr ->
             let mod_val = force (eval e !env) in
             (match mod_val with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  mod_val
              | _ -> failwith "import expects a module value")
         | ELoad path ->
             let source = Runtime.loader_read path in
             let exprs = Reader.read_string source in
             eval_expressions exprs env
         | _ ->
             let result = force (eval e !env) in
             (match result with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  result
              | _ -> result))
    | e :: rest ->
        (match unwrap e with
         | EDef (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             go rest
         | EDefNode (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             go rest
         | EDefValue (name, rhs) ->
             let v = eval rhs !env in
             env := extend_env !env name v;
             go rest
         | EImport mod_expr ->
             let mod_val = force (eval e !env) in
             (match mod_val with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  go rest
              | _ -> failwith "import expects a module value")
         | ELoad path ->
             let source = Runtime.loader_read path in
             let exprs = Reader.read_string source in
             ignore (eval_expressions exprs env);
             go rest
         | _ ->
             let result = force (eval e !env) in
             (match result with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  go rest
              | _ -> go rest))
  in
  go exprs

(* ---- Public API ---- *)

(* Evaluate an expression in the initial environment *)
let eval_program (e : expr) : value =
  let env = Primitives.initial_env () in
  eval e env

(* Evaluate and force (for top-level expressions) *)
let eval_and_force (e : expr) : value =
  force (eval_program e)

(* Initialize the evaluator state *)
let init () =
  handler_stack := [];
  current_capabilities := !initial_capabilities;
  if not !Runtime.keep_thunks then Hashtbl.clear thunk_store;
  Primitives.set_force force;
  Primitives.set_eval eval;
  Primitives.set_apply apply;
  (* Config values may be unforced thunks; their trace-cell observation (LAW 33)
     hashes the forced value, both at record time and at hit re-observation. *)
  Runtime.force_hook := force
