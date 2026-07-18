(* pp evaluator — strict (call-by-value) tree-walking evaluator; thunks are
   used only for `let`/`node`/`delay` bindings and node memoization, never
   for ordinary argument passing *)

open Core_model
open Source_error
open Hasher
open Dynamic_scope

(* ---- Evaluation State ---- *)

(* Create or retrieve a content-addressed thunk.
   Two thunks with the same (expr, env, capabilities) are the SAME thunk.
   Uses env.env_hash for O(1) environment identity — no recursive traversal. *)
let make_thunk_ca (expr : expr) (env : env) : value =
  let caps = Effect.perform Dynamic_scope.Get_capabilities in
  let cfg = Effect.perform Dynamic_scope.Get_config in
  let handlers = Effect.perform Dynamic_scope.Get_handlers in
  let caps_hash = Hasher.hash_concat ("caps" :: List.map Capability.hash caps) in
  let cfg_hash = Hasher.hash_concat ("cfg" :: List.map Identity.hash_value cfg) in
  let hh = Hasher.hash_concat ("handlers" :: List.concat_map (fun (n,h)->[n;h]) handlers) in
  let h = Hasher.hash_concat ["thunk"; Identity.hash_expr expr; env.env_hash; caps_hash; cfg_hash; hh] in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_thunk session h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; type_ann = None; thunk_loc = None; config_hash = cfg_hash; thunk_persist = false; node_caps = [] } in
      Session.add_thunk session h t;
      VThunk t

let make_thunk_ca_typed (expr : expr) (ty : expr) (loc : (string * int) option) (env : env) : value =
  let caps = Effect.perform Dynamic_scope.Get_capabilities in
  let cfg = Effect.perform Dynamic_scope.Get_config in
  let handlers = Effect.perform Dynamic_scope.Get_handlers in
  let caps_hash = Hasher.hash_concat ("caps" :: List.map Capability.hash caps) in
  let cfg_hash = Hasher.hash_concat ("cfg" :: List.map Identity.hash_value cfg) in
  let hh = Hasher.hash_concat ("handlers" :: List.concat_map (fun (n,h)->[n;h]) handlers) in
  let h = Hasher.hash_concat ["thunk-typed"; Identity.hash_expr expr; Identity.hash_expr ty; env.env_hash; caps_hash; cfg_hash; hh] in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_thunk session h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; type_ann = Some ty; thunk_loc = loc; config_hash = cfg_hash; thunk_persist = false; node_caps = [] } in
      Session.add_thunk session h t;
      VThunk t

(* Runtime check for gradual type annotations, kept at the evaluator boundary
   so every typed value follows the same check path. *)

let cell_authorized_for = Observation.authorized_id

(* Trace replay for an already-Evaluated persistent node: replay its stored
   trace reads into the active trace frames so the caller's trace transitively
   captures this node's world-reads (the same mechanism as cache hit replay).
   [key_of] is the node-key function (node_key_of). *)
let replay_node_reads = Node.replay_node_reads

(* Run a persistent node's body and store the result (LAW 21) or the failure
   (LAW 28) with its verifying trace. Shared by the evaluator's force and
   trampoline paths — the node caches identically however it is demanded.
   [run] executes the body. *)

(* Serve a resolved Cache_policy.result the same way in every miss-arm variant
   below: a verified hit (gated on LAW 23b authority), a re-served memoized
   failure (LAW 28), or [None] on Miss (caller decides what to do). *)

(* Force a persistent node through the store: serve a verified hit (gated on
   the caller's authority over the trace's read closure, LAW 23b), re-serve a
   memoized failure (LAW 28), or run and store on a miss.

   Miss-arm scheduling: under [Race n] with n > 1, a singleton miss is worth
   forking — n redundant (key, run) forks of the SAME job race each other
   (sound: LAW 37 nodes are deterministic), the parent never reads a value
   from any of them, and re-enters Cache_policy.lookup Cache_policy.default afterward exactly as the batch
   path does — a hit if some child won, a Miss (falling through to the
   ordinary in-process run below) if every child died. Under [Serial] or
   [Parallel _], a LONE miss stays in-process (width 1): forking a single job
   buys nothing (there is no second worker to race or overlap with) — only a
   force-deep BATCH benefits from forking, and that path (Primitives
   force-deep) dispatches its own batch before any of its members ever
   reaches this function as a Miss. *)
let force_node ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  Stabilize.register_node_key ~key ~thunk:t;
  (* LAW 23b: "the caller's capabilities" for the hit gate
     is THIS thunk's node_caps — captured at this process's creation of this
     `(node e)` occurrence — not necessarily current_capabilities right now.
     Absent with-caps the two are always equal (node_caps is populated from
     current_capabilities at creation and current_capabilities never changes
     without with-caps), so this collapses to the plain per-process
     `--grant` set whenever with-caps goes unused. *)
  let authorized = cell_authorized_for t.node_caps in
  match Node.serve_hit ~t (Cache_policy.lookup Cache_policy.default ~key ~authorized) with
  | Some v -> v
  | None ->
      (match Scheduler.state.policy with
       | Scheduler.Race n when n > 1 ->
           let job = { Scheduler.j_key = key;
                       j_run = (fun () -> Node.run_node_body ~key ~run t);
                       j_width = n; j_thunk = t } in
           Scheduler.dispatch_batch [job];
           (match Node.serve_hit ~t (Cache_policy.lookup Cache_policy.default ~key ~authorized) with
            | Some v -> v
            | None ->
                (* Every racing worker died: degrade to the ordinary serial
                   path — never a wrong answer, never a hang. *)
                Node.run_node_body ~key ~run t)
       (* A lone miss stays in-process under every OTHER policy too,
          including [Remote _]: spinning up a cluster-member subprocess for
          a single node buys nothing (there is no sibling to overlap with,
          same reasoning as Serial/Parallel above) — only a force-deep BATCH
          (collect_unevaluated_nodes, primitives.ml) is worth shipping. *)
       | Scheduler.Serial | Scheduler.Parallel _ | Scheduler.Race _
       | Scheduler.Remote _ ->
           Node.run_node_body ~key ~run t)

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
   error expression evaluates to the same text wherever it is forced. *)
let poison_expr (name : string) : expr =
  EApply (ESymbol "error",
          [ELiteral (VString (name ^ ": referenced before its definition"))])

let poison_thunk (name : string) (env : env) : value =
  Environment.make_thunk (poison_expr name) env

(* ---- Force: evaluate a thunk on demand ---- *)

(* Depth limit before switching to heap-allocated trampoline.
   OCaml's default stack handles ~10k small frames; 2000 gives
   ample headroom while keeping the trampoline nesting shallow
   even for 10^6-deep recursion (~500 trampoline entries). *)
let max_force_depth = 2000
let session () = Effect.perform Dynamic_scope.Get_session
let force_depth () = Session.force_depth (session ())
let set_force_depth n = Session.set_force_depth (session ()) n
let incr_force_depth () = Session.incr_force_depth (session ())
let decr_force_depth () = Session.decr_force_depth (session ())



(* Main force entry-point: uses native stack for shallow chains,
   switches to trampoline when depth exceeds threshold. *)
let rec force (v : value) : value =
  incr_force_depth ();
  match v with
  | _ when force_depth () > max_force_depth ->
      let saved = force_depth () in
      set_force_depth 0;
      let r = trampoline_force v in
      set_force_depth saved;
      decr_force_depth ();
      r
  | VThunk t ->
      (match t.thunk_status with
       | Evaluated result ->
           decr_force_depth ();
           Node.replay_node_reads t node_key_of;
           force result
       | Evaluating ->
           decr_force_depth ();
           failwith "infinite recursion detected (forcing a thunk already being evaluated)"
       | Unevaluated ->
           (* Persistent nodes route through the store. Identity is the
              LAW 20 node key (code + free-var value hashes); the trace decides
              validity. A stale trace falls through to recompute. *)
           if t.thunk_persist then
             let nk = node_key_of t in
              let run () = eval t.thunk_expr t.thunk_env in
             (match force_node ~key:nk ~run t with
              | result -> decr_force_depth (); force result
              | exception e -> decr_force_depth (); raise e)
           else
             evaluate_and_store_no_key t)
  | _ ->
      decr_force_depth ();
      v

and evaluate_and_store_no_key (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let result =
    try
          eval t.thunk_expr t.thunk_env
    with e ->
      (* An ephemeral thunk that raised must not be left `Evaluating`, or
         the next force misreports "infinite recursion". Reset and re-raise the
         real error (ephemeral thunks are not failure-cached). *)
      t.thunk_status <- Unevaluated;
      decr_force_depth ();
      raise e
  in
  (* enforce_type resets thunk_status on failure; also unwind force_depth,
     which is evaluator-local, so a failed check does not leak trampoline
     depth (the body-eval guard above already decrements on its own raise). *)
  (try Node.enforce_type t result with e -> decr_force_depth (); raise e);
  t.thunk_status <- Evaluated result;
  decr_force_depth ();
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
  let fv_hashes =
    Free_vars.SS.elements (Free_vars.free_vars e)
    |> List.map (fun name ->
      match Environment.lookup t.thunk_env name with
      | Some v -> Node.fv_hash ~name v force
      | None -> Node.unbound_fv_hash ~name)
  in
  Hasher.node_key_skeleton ~expr_hash:(Identity.hash_expr e) fv_hashes

(* Remote placement: a
   node is data-closed iff every free var's FORCED value re-encodes under
   Codec.encode_value — the store's own non-data predicate (codec.ml),
   reused verbatim at this new decision point rather than duplicated.
   Mirrors node_key_of's own free-var walk/force (so "can this key be
   computed" and "can this node be shipped" agree on what counts as a free
   var) but never raises: a free var that forces to a capability/sealed
   value (node_key_of's own ban above) or that raises for any other reason
   is conservatively treated as NOT data-closed — the degrade-to-local
   posture, never a crash and never a wrong ship. An unbound name (a
   reference to a global/primitive function that initial_env never even
   populated) needs nothing shipped, so it never blocks shipping the node
   itself.

   VBuiltin is a documented, necessary carve-out to the literal codec
   check: `Primitives.initial_env` binds EVERY primitive into the base
   env (repl.ml), so an ordinary reference to `slurp`/`string-append`/etc.
   — present in nearly every real node body — resolves via [Environment.lookup]
   exactly like a captured user value would, and forcing it yields a
   VBuiltin, which [Codec.encode_value] correctly refuses (it is code, the
   store's non-data law). But a bare reference to a global primitive is
   NOT "shipping code" the way a captured VClosure over user state would
   be: it is part of the identical program source both sides already run,
   resolved identically by construction (the same pp binary's own builtin
   table) — the exact "no code crosses the wire" invariant the source-hash
   check already establishes at a coarser grain. A genuinely captured
   VClosure is deliberately NOT exempted here — that free var really would
   need code shipped, so it correctly still fails the encode check below,
   exactly like Codec.encode_value already treats it (the "free var is a
   closure stays local" contract scenario). *)
and is_data_closed (t : thunk) : bool =
  Free_vars.SS.for_all (fun name ->
    match Environment.lookup t.thunk_env name with
    | None -> true
    | Some v ->
        (try
           match force v with
           | VBuiltin _ -> true
           | fv -> Codec.encode_value fv <> None
         with _ -> false))
    (Free_vars.free_vars t.thunk_expr)

(* ---- Main Evaluator (non-tail) ---- *)

and eval (e : expr) (env : env) : value =
  Session.set_current_env (session ()) env;
  eval_tail e env (fun v -> v)

(* ---- Tail-position evaluator ---- *)
(* eval_tail e env k: evaluates e in tail position with continuation k.
   The continuation k is threaded through tail calls without growing the
   OCaml stack — this is how TCO works. *)

and eval_tail (e : expr) (env : env) (k : value -> value) : value =
  Session.set_current_env (session ()) env;
  match e with
  | ELiteral v -> k v

  | ESymbol name ->
      (match Environment.lookup env name with
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
        Environment.extend e name thunk
      ) env thunks in
      List.iter (fun (_, thunk) ->
        match thunk with
        | VThunk t -> t.thunk_env <- env_mutual
        | _ -> ()
      ) thunks;
      eval_tail body env_mutual k

  | EFn (params, body) ->
      k (Environment.make_closure ~name:None params body (ref env))

  | EApply (fn_expr, arg_exprs) ->
      (* Strict application: force fn and all args before calling.
         This is call-by-value: arguments are evaluated before the body runs. *)
      let fn_val = force (eval fn_expr env) in
      let arg_vals = List.map (fun arg_expr -> force (eval arg_expr env)) arg_exprs in
      apply_tail fn_val arg_vals env k

  | EQuote e ->
      k (Quotation.quote_to_value e)

  | EDelay e ->
      k (make_thunk_ca e env)

  | EForce e ->
      (* EForce in tail position: eval the inner expression in tail position,
         then force the result and pass to k *)
      k (force (eval e env))
  | ENode e ->
      let thunk_val = make_thunk_ca e env in
      (match thunk_val with
       | VThunk t ->
           t.thunk_persist <- true;
           t.node_caps <- Effect.perform Dynamic_scope.Get_capabilities
       | _ -> ());
      k thunk_val

  | EDef (name, params, body) ->
      k (Environment.make_closure ~name:(Some name) params body (ref env))

  | EDefNode (name, params, body) ->
      k (Environment.make_closure ~name:(Some name) params body (ref env))

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
            env_ref := Environment.extend !env_ref name p
        | _ -> ()) exprs;
      let rec go = function
        | [] -> k VNil
        | [last] -> eval_tail last !env_ref k
        | (EDef (name, params, body)) :: rest ->
            let closure = Environment.make_closure ~name:(Some name) params body env_ref in
            env_ref := Environment.extend !env_ref name closure;
            go rest
        | (EDefNode (name, params, body)) :: rest ->
            let closure = Environment.make_closure ~name:(Some name) params body env_ref in
            env_ref := Environment.extend !env_ref name closure;
            go rest
        | (EDefValue (name, rhs)) :: rest ->
            let v = eval rhs !env_ref in
            (match Hashtbl.find_opt poisons name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            env_ref := Environment.extend !env_ref name v;
            go rest
        | (EImport mod_expr) :: rest ->
            let mod_val = force (eval mod_expr !env_ref) in
            (match mod_val with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   Environment.extend e n v) !env_ref bindings;
                 go rest
             | _ -> failwith "import expects a module value")
        | (ELoad path) :: rest ->
            (* `~source:path`: the loaded file's OWN path, so its top-level
               forms are located against it (not the reader's "<?>"
               default) — LAW 29, via eval_expressions below,
               which per-form-locates each of the loaded file's forms.
               Macro expansion runs at this source-entry boundary so a
               `load`ed file's macros are visible to the rest of THIS
               file's forms and vice versa (load is sequential evaluation,
               one shared macro table — Macro.ml's documented decision). *)
            let contents = Loader.read path in
            let exprs = expand_toplevel
                          (Reader_braces.read_dispatch ~source:path ~path contents) in
            ignore (eval_expressions exprs env_ref);
            go rest
        | (ELoadModule path) :: rest ->
            (match eval_module_file path with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   Environment.extend e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
        | e :: rest ->
            let result = force (eval e !env_ref) in
            (match result with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   Environment.extend e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
      in
      go exprs
  | EWithCaps (cap_expr, body) ->
      (* REPLACES the dynamic ambient with exactly the requested cap for the
         body's extent (never a union — that was the removed `effect` form's
         widening backdoor), gated by cap_subseteq against the CURRENT
         ambient (not the root grant), so narrowing composes even when code
         lexically retains a broader value. *)
      let cap_val = force (eval cap_expr env) in
      let requested =
        match cap_val with
        | VCapability c -> c
        | _ -> failwith "with-caps expects a capability value"
      in
      if not (Capability.subseteq requested (Dynamic_scope.capabilities ())) then
        raise (Capability_error Capability.err_with_caps_widen);
      Dynamic_scope.with_capabilities [requested] (fun () -> eval_tail body env k)

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      k (perform_effect name forced_args)

  | EWithHandler (handlers, body) ->
      let new_handlers = List.map (fun (name, handler_expr) ->
        let handler_val = force (eval handler_expr env) in
        (name,
         (fun args -> apply handler_val args env),
         Identity.hash_value handler_val)   (* handler identity in the key *)
      ) handlers in
      Dynamic_scope.with_handlers new_handlers (fun () -> eval_tail body env k)
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
            let env'' = Environment.extend env' name thunk in
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
            Environment.extend acc name p
        | _ -> acc) !mod_env body_exprs in
      mod_env := prebound_env;
      let final_env = List.fold_left (fun (env_acc : env) e ->
        match e with
        | EDef (def_name, params, body) ->
            let closure = Environment.make_closure ~name:(Some def_name) params body (ref env_acc) in
            Environment.extend env_acc def_name closure
        | EDefNode (def_name, params, body) ->
            let closure = Environment.make_closure ~name:(Some def_name) params body (ref env_acc) in
            Environment.extend env_acc def_name closure
        | EDefValue (def_name, rhs) ->
            let v = eval rhs env_acc in
            (match Hashtbl.find_opt poisons def_name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            Environment.extend env_acc def_name v
        | EImport mod_expr ->
            let mod_val = force (eval mod_expr env_acc) in
            (match mod_val with
             | VEnvMap bindings ->
                 List.fold_left (fun e (n, v) -> Environment.extend e n v) env_acc bindings
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
      (* Same source-entry expansion treatment as EDo's ELoad
         arm above. *)
      let contents = Loader.read path in
      let exprs = expand_toplevel
                    (Reader_braces.read_dispatch ~source:path ~path contents) in
      let env_ref = ref env in
      k (eval_expressions exprs env_ref)

  | ELoadModule path ->
      k (eval_module_file path)

  | ELocated (loc, ETyped (e, ty)) ->
      (* A located annotation becomes a typed thunk carrying the location. *)
      k (make_thunk_ca_typed e ty (Some loc) env)
  | ELocated (_, e) -> eval_tail e env k
  | ETyped (e, ty) ->
      (* Type annotations defer evaluation into a thunk whose result is
         checked at force time. *)
      k (make_thunk_ca_typed e ty None env)
  | EIsland (uri, pin) ->
      (* Resolve the inline pin to the immutable cached tree (verified
         against the pin on every resolve), then evaluate its entry.pp as a
         module. The pin is part of this expression's hash, so island
         identity is structural (LAW 20) — no trace cell. *)
      let tree = Island.resolve ~uri ~pin in
      k (eval_module_file (Island.entry_file tree))
  | EWithConfig (map_expr, body) ->
      let cfg = force (eval map_expr env) in
      let eval_body () =
        Dynamic_scope.with_config cfg (fun () -> eval_tail body env k)
      in
      (match cfg with
       | VMap _ -> eval_body ()
       | _ -> failwith "with-config expects a map")
  | EConfig (key_expr, default_opt) ->
      let key_val = force (eval key_expr env) in
      let key_name = match key_val with
        | VString s | VKeyword s | VSymbol s -> s
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      (* LAW 33: reading config inside a node is an observation — recorded as a
         `config:<key>` trace cell (absence included), never part of the key. *)
      Observation.record_config key_name;
      (match Dynamic_scope.config_lookup key_name with
       | Some v -> k v
       | None ->
           (match default_opt with
            | Some d -> eval_tail d env k
            | None -> k VNil))

  | EMatch (scrutinee, arms) ->
      let v = force (eval scrutinee env) in
      let rec try_arms = function
        | [] -> failwith "match failure"
        | (pat, guard, body) :: rest ->
            (match Pattern_match.match_pattern v pat with
             | Some binds ->
                 let env' = List.fold_left (fun e (n, v) -> Environment.extend e n v) env binds in
                 (* A guard is evaluated under the arm's bindings; a falsy guard
                    falls through to the next arm. Only nil/false are falsy. *)
                 let fires = match guard with
                   | None -> true
                   | Some g -> (match force (eval g env') with VBool false | VNil -> false | _ -> true)
                 in
                 if fires then eval_tail body env' k else try_arms rest
             | None -> try_arms rest)
      in
      try_arms arms

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
        Environment.extend e param arg  (* arg is already a thunk *)
      ) !closure_env params args in
      eval_tail body env' k

  | VBuiltin (_, f) ->
      (* No re-wrapping of the error text: primitives name themselves in their
         own messages, and wrapping here would mangle user `error` messages. *)
      Session.set_current_env (session ()) env;
      k (f args)

  | _ ->
      failwith (Printf.sprintf "not a function: %s" (Presentation.string_of_value fn))


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
                    let saved = force_depth () in
                    set_force_depth 0;
                    let r = eval t.thunk_expr t.thunk_env in
                    set_force_depth saved;
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
                    let saved = force_depth () in
                    set_force_depth 0;
                    let r = eval t.thunk_expr t.thunk_env in
                    set_force_depth saved;
                    r
                  in
                  (match t.type_ann with
                   | Some ty -> Node.check_type result ty t.thunk_loc
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
  Observation.record_handler name;
  (* Check for handler via effect perform *)
  match Effect.perform (Dynamic_scope.Lookup_handler name) with
  | Some (handler, _) -> handler args
  | None -> perform_builtin_effect name args

and perform_builtin_effect (name : string) (args : value list) : value =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           (* Node-local sandbox scratch reads are capability-free and
              unrecorded (LAW 18) — scratch is the node's working memory.
              Outside a sandbox: an fs-read grant returns plain data
              (CAS-ingested, pinned for the run), a CapSecret-only grant
              returns VSealed; see Process.read_dispatch. *)
           Process.read_dispatch ~tag:"read-file"
             ~cap_err:(fun p -> "read-file: capability error: no read access for " ^ p) path
       | _ -> failwith "read-file expects a string path")
  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           (* LAW 18: inside a node, relative ⇒ sandbox scratch, absolute ⇒
              error; scripting tier unchanged (Process.write_file_effect). *)
           Process.write_file_effect ~has_cap:has_fs_write path content
       | _ -> failwith "write-file expects path and content strings")

  | "run" ->
      (* Process execution — capability-gated, trace-recorded, sandboxed
         (process.ml). *)
      Process.run_effect args

  | "run-dep!" ->
      (* run + depfile → precise cells, no coarse tree cells.
         `!`-suffixed — the effect name carries the effect marker, since
         this effect trusts the tool's own report of what it read rather
         than observing a whole granted tree. *)
      Process.run_dep_effect args

  | "http-get" ->
      (match args with
       | [VString url] -> Process.http_request ~method_:"GET" ~url ~body:None
       | _ -> failwith "http-get expects a url string")

  | "http-post" ->
      (match args with
       | [VString url; VString body] ->
           Process.http_request ~method_:"POST" ~url ~body:(Some body)
       | _ -> failwith "http-post expects a url string and a body string")

  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg;
           VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg;
           VNil
       | _ -> failwith "log expects a message string")

  (* ---- Domain primitives (src/domain_prims.ml) ---- *)

  | "tree-observe" ->
      (match args with
       | [VString root] -> Domain_prims.tree_observe root
       | _ -> failwith "tree-observe expects a root path string")

  | "materialize-file" ->
      (match args with
       | [VString path; VString content] ->
           Domain_prims.materialize_file path content false; VNil
       | [VString path; VString content; VKeyword "executable"] ->
           Domain_prims.materialize_file path content true; VNil
       | _ -> failwith "materialize-file expects a path, content, and optional :executable"
      )

  | "remove-file" ->
      (match args with
       | [VString path] -> Domain_prims.remove_file path; VNil
       | _ -> failwith "remove-file expects a path string")

  | "proc-spawn" ->
      (match args with
       | [spec] -> Domain_prims.proc_spawn spec
       | _ -> failwith "proc-spawn expects a spec map")

  | "proc-alive?" ->
      (match args with
       | [VInt pid] -> VBool (Domain_prims.proc_alive pid)
       | _ -> failwith "proc-alive? expects a pid integer")

  | "proc-stop" ->
      (match args with
       | [VString name; VInt pid] -> Domain_prims.proc_stop name pid; VNil
       | _ -> failwith "proc-stop expects a service name and a pid integer")

  | "proc-reap" ->
      (match args with
       | [] -> Domain_prims.proc_reap (); VNil
       | _ -> failwith "proc-reap takes no arguments")

  | "domain-state-get" ->
      (match args with
       | [VString key] -> Domain_prims.domain_state_get key
       | _ -> failwith "domain-state-get expects a key string")

  | "domain-state-put" ->
      (match args with
       | [VString key; v] -> Domain_prims.domain_state_put key v; VNil
       | _ -> failwith "domain-state-put expects a key string and a value")

  | _ ->
      failwith ("unhandled effect: " ^ name)

(* ---- Helpers ---- *)

and has_fs_read (path : string) : bool =
  List.exists (fun cap -> Capability.check_fs_read cap (World_path.canonical path)) (Effect.perform Dynamic_scope.Get_capabilities)

and has_fs_write (path : string) : bool =
  List.exists (fun cap -> Capability.check_fs_write cap (World_path.canonical path)) (Effect.perform Dynamic_scope.Get_capabilities)

and expand_toplevel exprs =
  Macro.expand_toplevel_list
    { Macro.eval = eval;
      force_deep = Primitives.force_deep;
      initial_env = Primitives.initial_env }
    exprs

(* (load-module "file.pp"): evaluate the file against a fresh initial env and
   package the bindings it added as a module value. Shared by the tail
   evaluator and EDo. *)
and eval_module_file (path : string) : value =
  let source = Loader.read path in
  (* Dispatch on [path]'s extension; the location label stays the
     reader's "<?>" default. *)
  let exprs = expand_toplevel
                (Reader_braces.read_dispatch ~path source) in
  let mod_ref = ref (Primitives.initial_env ()) in
  ignore (eval_expressions exprs mod_ref);
  VEnvMap (new_bindings ~base:(Primitives.initial_env ()).bindings (!mod_ref).bindings)

(* Evaluate expressions sequentially with mutable env — used by ELoad, ELoadModule, and REPL.
   `exprs` is always a list of top-level-shaped forms straight out of
   Reader.read_string (the top-level file/REPL driver, or a `load`ed file's
   own top-level forms), so every element is individually `ELocated`. *)
and eval_expressions (exprs : expr list) (env : env ref) : value =
  let unwrap e = match e with ELocated (_, e') -> e' | _ -> e in
  (* Evaluate ONE form, mutating `env` for defs/imports; wrapped in ITS OWN
     location (LAW 29): an error escaping this form is decorated with
     this form's file:line before it can unwind past a `load` that brought
     it in — never doubled if a deeper form already located it. *)
  let step (e : expr) : value =
    Error_context.with_form_location e (fun () ->
      match unwrap e with
      | EDef (name, params, body) ->
          let closure = Environment.make_closure ~name:(Some name) params body env in
          env := Environment.extend !env name closure;
          closure
      | EDefNode (name, params, body) ->
          let closure = Environment.make_closure ~name:(Some name) params body env in
          env := Environment.extend !env name closure;
          closure
      | EDefValue (name, rhs) ->
          (* Top level is sequential: the RHS is evaluated now (a forward
             reference is an unbound-symbol error), the value bound. *)
          let v = eval rhs !env in
          env := Environment.extend !env name v;
          v
      | EImport _ ->
          let mod_val = force (eval e !env) in
          (match mod_val with
           | VEnvMap bindings ->
               env := List.fold_left (fun env' (n, v) ->
                 Environment.extend env' n v) !env bindings;
               mod_val
           | _ -> failwith "import expects a module value")
      | ELoad path ->
          (* `~source:path`: the loaded file's OWN path (not the reader's
             "<?>" default), so ITS forms are in turn correctly located.
             Expanded at this source-entry boundary, same as every
             other Reader.read_string call site. *)
          let contents = Loader.read path in
          let sub_exprs = expand_toplevel
                            (Reader_braces.read_dispatch ~source:path ~path contents) in
          eval_expressions sub_exprs env
      | _ ->
          let result = force (eval e !env) in
          (match result with
           | VEnvMap bindings ->
               env := List.fold_left (fun env' (n, v) ->
                 Environment.extend env' n v) !env bindings;
               result
           | _ -> result))
  in
  let rec go = function
    | [] -> VNil
    | [e] -> step e
    | e :: rest -> ignore (step e); go rest
  in
  go exprs
(* ---- Public API ---- *)

(* Evaluate an expression in the initial environment *)
let eval_program (e : expr) : value =
  Dynamic_scope.with_top_level (Effect.perform Dynamic_scope.Get_session)
    (Effect.perform Dynamic_scope.Get_invocation) ~f:(fun () ->
    let env = Primitives.initial_env () in
    eval e env
  ) ()

(* Evaluate and force (for top-level expressions) *)
let eval_and_force (e : expr) : value =
  Dynamic_scope.with_top_level (Effect.perform Dynamic_scope.Get_session)
    (Effect.perform Dynamic_scope.Get_invocation) ~f:(fun () ->
    force (eval_program e)
  ) ()

(* Initialize the evaluator state *)
let resolve_if_hit t key =
  match Cache_policy.lookup Cache_policy.default ~key ~authorized:(cell_authorized_for t.node_caps) with
  | Cache_policy.HitOk value -> t.thunk_status <- Evaluated value; true
  | Cache_policy.HitFailed _ -> true
  | Cache_policy.Miss -> false

let operations = {
  Evaluator_ops.core = { force; eval; apply };
  node = {
    key_of = node_key_of;
    run_body = (fun ~key ~run thunk -> Node.run_node_body ~key ~run thunk);
    resolve_hit = resolve_if_hit;
  };
}

let init session ~retain_thunks =
  Session.begin_evaluation ~retain_thunks session
