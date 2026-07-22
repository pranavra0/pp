open Pp_kernel
(* pp evaluator — strict (call-by-value) tree-walking evaluator; thunks are
   used only for `let`/`node`/`delay` bindings and node memoization, never
   for ordinary argument passing *)

open Core_model

let force_node = Evaluator_node.force

let make_thunk_ca = Evaluator_thunks.make
let make_thunk_ca_typed = Evaluator_thunks.make_typed

type continuation =
  | Stop
  | Force of continuation
  | Branch of expr * expr * env * continuation
  | Apply_function of expr list * env * continuation
  | Apply_argument of value * expr list * value list * env * continuation

let max_eval_depth = 2000

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
let eval_depth () = Session.eval_depth (session ())
let set_eval_depth n = Session.set_eval_depth (session ()) n
let incr_eval_depth () = Session.incr_eval_depth (session ())
let decr_eval_depth () = Session.decr_eval_depth (session ())

let force_cycle (t : thunk) : 'a =
  let rec suffix = function
    | [] -> []
    | current :: rest ->
        if current == t then current :: rest else suffix rest
  in
  let active_forces = Session.force_path (session ()) in
  let path = match suffix (List.rev active_forces) with
    | [] -> [t]
    | path -> path @ [t]
  in
  let name = function
    | { thunk_name = Some name; _ } -> name
    | _ -> "<anonymous binding>"
  in
  Source_error.eval
    ("cyclic binding: " ^ String.concat " -> " (List.map name path))

let with_force_frame (t : thunk) f =
  let session = session () in
  Session.set_force_path session (t :: Session.force_path session);
  Fun.protect f ~finally:(fun () ->
    match Session.force_path session with
    | current :: rest when current == t -> Session.set_force_path session rest
    | path -> Session.set_force_path session
                 (List.filter (fun other -> other != t) path))



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
           if Evaluator_thunks.is_persistent t then
             Option.iter (fun id ->
               Effect.perform (Dynamic_scope.Record_node_force id)) t.thunk_hash;
           decr_force_depth ();
           Node.record_node_dependency t;
           force result
       | Evaluating ->
           decr_force_depth ();
           force_cycle t
       | Unevaluated ->
           (* Persistent nodes route through the store. Identity is the
              node key (code + free-variable and argument value hashes); the
              trace decides validity. A stale trace falls through to recompute. *)
           if Evaluator_thunks.is_persistent t then
             (match with_force_frame t (fun () ->
                let nk = node_key_of t in
                let run () = eval t.thunk_expr t.thunk_env in
                force_node ~key:nk ~run t) with
              | result -> decr_force_depth (); force result
              | exception e -> decr_force_depth (); raise e)
           else
             evaluate_and_store_no_key t)
  | _ ->
      decr_force_depth ();
      v

and evaluate_and_store_no_key (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let result = with_force_frame t (fun () ->
    try eval t.thunk_expr t.thunk_env with e ->
      t.thunk_status <- Unevaluated;
      decr_force_depth ();
      raise e)
  in
  (* enforce_type resets thunk_status on failure; also unwind force_depth,
     which is evaluator-local, so a failed check does not leak trampoline
     depth (the body-eval guard above already decrements on its own raise). *)
  (try Node.enforce_type t result with e -> decr_force_depth (); raise e);
  t.thunk_status <- Evaluated result;
  decr_force_depth ();
  force result

(* A node's persistent key is its code structure plus the *value* hashes of
   its free variables and applied arguments. Free variables are forced
   call-by-value because the key cannot exist before their values do. The
   whole environment hash, capability set, and ambient config/handler stacks
   are excluded: config values and handlers observed by the node are recorded
   in its trace as `config:`/`handler:` cells, which govern validity rather
   than identity. *)
and node_key_of (t : thunk) : Identity_types.Node_key.t =
  let dependencies = ref [] in
  let key =
    try
      Node.key_of ~expr:t.thunk_expr ~env:t.thunk_env ~force
        ~argument_values:(Evaluator_thunks.argument_values t)
    with
    | effect (Dynamic_scope.Record_node_force id), continuation ->
        if not (List.mem id !dependencies) then dependencies := id :: !dependencies;
        Effect.Deep.continue continuation ()
  in
  let session = session () in
  List.iter (fun id -> Session.add_node_dependent session id key) !dependencies;
  ignore (Event_sink.emit (Session.event_sink session)
    (Event.Identity_node_key_computed key));
  key

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
  incr_eval_depth ();
  if eval_depth () > max_eval_depth then begin
    let saved = eval_depth () in
    set_eval_depth 0;
    Fun.protect
      (fun () -> eval_machine e env Stop)
      ~finally:(fun () -> set_eval_depth (saved - 1))
  end else
    match eval_tail e env (fun v -> decr_eval_depth (); v) with
    | result -> result
    | exception exn -> decr_eval_depth (); raise exn

(* ---- Tail-position evaluator ---- *)
(* eval_tail e env k: evaluates e in tail position with continuation k.
   The continuation k is threaded through tail calls without growing the
   OCaml stack — this is how TCO works. *)

and eval_tail (e : expr) (env : env) (k : value -> value) : value =
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
      (* Mutual let: all bindings are visible in every RHS.
         Create thunks with outer env, build mutual env, then backpatch
         each thunk's env so they see each other when forced. *)
      let thunks = List.map (fun (name, binding_expr) ->
        (name, make_thunk_ca ~name binding_expr env)
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
      Evaluator_application.apply_tail
        { eval_tail; force }
        fn_val arg_vals env k

  | EQuote e ->
      k (Quotation.quote_to_value e)

  | EDelay e ->
      k (make_thunk_ca e env)

  | EForce e ->
      (* EForce in tail position: eval the inner expression in tail position,
         then force the result and pass to k *)
      k (force (eval e env))
  | ENode e ->
      k (Evaluator_thunks.make_node e env ~arguments:[])

  | (EDef _ | EDefNode _) as definition ->
      (match Evaluator_forms.definition_of_expr definition with
       | Some { name; params; body; kind } ->
           k (Environment.make_definition ~name ~kind params body (ref env))
       | None -> failwith "invalid definition")

  | EDo exprs ->
      Evaluator_forms.do_block
        { eval; eval_tail; force }
        exprs env k
  | EWithCaps (cap_expr, body) ->
      Evaluator_scope.with_caps { eval; eval_tail; force; apply }
        cap_expr body env k

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      k (Evaluator_effects.perform ~application:apply name forced_args)

  | EWithHandler (handlers, body) ->
      Evaluator_scope.with_handlers { eval; eval_tail; force; apply }
        handlers body env k
  | EDefValue (_, rhs) ->
      (* Bare expression position: evaluate the RHS and return it; binding is
         the job of the enclosing block / top level (mirrors EDef, which
         returns its closure without binding here). *)
      k (eval rhs env)

  | ELetStar (bindings, body) ->
      let rec nest env' = function
        | [] -> eval_tail body env' k
        | (name, expr) :: rest ->
            let thunk = make_thunk_ca ~name expr env' in
            let env'' = Environment.extend env' name thunk in
            nest env'' rest
      in
      nest env bindings

  | EModule body_exprs ->
      k (Evaluator_forms.module_expr { eval; eval_tail; force } body_exprs)

  | EImport mod_expr ->
      let mod_val = force (eval mod_expr env) in
      k mod_val

  | ELoad path ->
      k (Evaluator_forms.load { eval; eval_tail; force } path env)

  | ELoadModule path ->
      k (Evaluator_forms.module_file { eval; eval_tail; force } path)

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
         identity is structural — no trace cell. *)
      let tree = Island.resolve ~uri ~pin in
      k (Evaluator_forms.module_file { eval; eval_tail; force }
           (Island.entry_file tree))
  | EWithConfig (map_expr, body) ->
      Evaluator_scope.with_config { eval; eval_tail; force; apply }
        map_expr body env k
  | EConfig (key_expr, default_opt) ->
      let key_val = force (eval key_expr env) in
      let key_name = match key_val with
        | VString s | VKeyword s | VSymbol s -> s
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      Evaluator_scope.read_config { eval; eval_tail; force; apply }
        key_name default_opt env k

  | EMatch (scrutinee, arms) ->
      let v = force (eval scrutinee env) in
      Evaluator_match.eval ~force ~eval ~eval_tail v arms env k

and apply (fn : value) (args : value list) (env : env) : value =
  Evaluator_application.apply
    { eval_tail; force }
    fn args env


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
            | Evaluating -> force_cycle t
            | Unevaluated ->
                if Evaluator_thunks.is_persistent t then begin
                  let h = node_key_of t in
                  let run () =
                    let saved = force_depth () in
                    set_force_depth 0;
                    let r = eval t.thunk_expr t.thunk_env in
                    set_force_depth saved;
                    r
                  in
                  let result = with_force_frame t (fun () -> force_node ~key:h ~run t) in
                  Queue.add result queue;
                  loop ()
                end else begin
                  (* ephemeral thunk — no store check *)
                  t.thunk_status <- Evaluating;
                  let result = with_force_frame t (fun () ->
                    let saved = force_depth () in
                    set_force_depth 0;
                    Fun.protect
                      (fun () -> eval t.thunk_expr t.thunk_env)
                      ~finally:(fun () -> set_force_depth saved))
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

and eval_machine (e : expr) (env : env) (k : continuation) : value =
  match e with
  | ELiteral value -> continue k value
  | ESymbol name ->
      (match Environment.lookup env name with
       | Some value -> continue k (force value)
       | None ->
           (match Primitives.lookup name with
            | Some value -> continue k value
            | None -> failwith ("unbound symbol: " ^ name)))
  | EIf (condition, yes, no) ->
      eval_machine condition env (Force (Branch (yes, no, env, k)))
  | ELet (bindings, body) ->
      let thunks = List.map (fun (name, expression) ->
        name, make_thunk_ca ~name expression env) bindings in
      let mutual = List.fold_left (fun scope (name, thunk) ->
        Environment.extend scope name thunk) env thunks in
      List.iter (fun (_, thunk) -> match thunk with
        | VThunk value -> value.thunk_env <- mutual
        | _ -> ()) thunks;
      eval_machine body mutual k
  | EFn (params, body) ->
      continue k (Environment.make_closure ~name:None params body (ref env))
  | EApply (fn, arguments) ->
      eval_machine fn env (Force (Apply_function (arguments, env, k)))
  | EQuote expression -> continue k (Quotation.quote_to_value expression)
  | EDelay expression -> continue k (make_thunk_ca expression env)
  | EForce expression -> eval_machine expression env (Force k)
  | ENode expression ->
      continue k (Evaluator_thunks.make_node expression env ~arguments:[])
  | (EDef _ | EDefNode _) as definition ->
      (match Evaluator_forms.definition_of_expr definition with
       | Some { name; params; body; kind } ->
           continue k (Environment.make_definition ~name ~kind params body (ref env))
       | None -> failwith "invalid definition")
  | EDo expressions ->
      Evaluator_forms.do_block
        { eval; eval_tail = (fun e env next -> eval_machine e env Stop |> next);
          force }
        expressions env (continue k)
  | EWithCaps (capability, body) ->
      Evaluator_scope.with_caps
        { eval; eval_tail = (fun e env next -> eval_machine e env Stop |> next);
          force; apply }
        capability body env (continue k)
  | EPerform (name, arguments) ->
      let values = List.map (fun argument -> make_thunk_ca argument env) arguments
                   |> List.map force in
      continue k (Evaluator_effects.perform ~application:apply name values)
  | EWithHandler (handlers, body) ->
      Evaluator_scope.with_handlers
        { eval; eval_tail = (fun e env next -> eval_machine e env Stop |> next);
          force; apply }
        handlers body env (continue k)
  | EDefValue (_, rhs) -> eval_machine rhs env k
  | ELetStar (bindings, body) ->
      let scope = List.fold_left (fun scope (name, expression) ->
        Environment.extend scope name (make_thunk_ca ~name expression scope))
        env bindings in
      eval_machine body scope k
  | EModule body ->
      continue k (Evaluator_forms.module_expr { eval; eval_tail; force } body)
  | EImport expression -> eval_machine expression env (Force k)
  | ELoad path ->
      continue k (Evaluator_forms.load { eval; eval_tail; force } path env)
  | ELoadModule path ->
      continue k (Evaluator_forms.module_file { eval; eval_tail; force } path)
  | ELocated (location, ETyped (expression, ty)) ->
      continue k (make_thunk_ca_typed expression ty (Some location) env)
  | ELocated (_, expression) -> eval_machine expression env k
  | ETyped (expression, ty) ->
      continue k (make_thunk_ca_typed expression ty None env)
  | EIsland (uri, pin) ->
      let tree = Island.resolve ~uri ~pin in
      continue k (Evaluator_forms.module_file { eval; eval_tail; force }
                    (Island.entry_file tree))
  | EWithConfig (config, body) ->
      Evaluator_scope.with_config
        { eval; eval_tail = (fun e env next -> eval_machine e env Stop |> next);
          force; apply }
        config body env (continue k)
  | EConfig (key, default) ->
      let key = force (eval_machine key env Stop) in
      let name = match key with
        | VString value | VKeyword value | VSymbol value -> value
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      Evaluator_scope.read_config { eval; eval_tail; force; apply }
        name default env (continue k)
  | EMatch (scrutinee, arms) ->
      let value = force (eval_machine scrutinee env Stop) in
      Evaluator_match.eval ~force ~eval
        ~eval_tail:(fun e env next -> eval_machine e env Stop |> next)
        value arms env (continue k)

and continue (k : continuation) (value : value) : value =
  match k with
  | Stop -> value
  | Force rest -> continue rest (force value)
  | Branch (yes, no, env, rest) ->
      (match value with
       | VBool false | VNil -> eval_machine no env rest
       | _ -> eval_machine yes env rest)
  | Apply_function (arguments, env, rest) ->
      (match arguments with
       | [] -> apply_machine value [] env rest
       | argument :: remaining ->
           eval_machine argument env
             (Force (Apply_argument (value, remaining, [], env, rest))))
  | Apply_argument (fn, [], reversed, env, rest) ->
      apply_machine fn (List.rev (value :: reversed)) env rest
  | Apply_argument (fn, argument :: remaining, reversed, env, rest) ->
      eval_machine argument env
        (Force (Apply_argument (fn, remaining, value :: reversed, env, rest)))

and apply_machine (fn : value) (args : value list) (env : env)
    (k : continuation) : value =
  match fn with
  | VClosure { fn_name; params; body; env = closure_env;
               closure_kind = Function } ->
      if List.length params <> List.length args then begin
        let name = Option.value ~default:"#<fn>" fn_name in
        failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d"
                    name (List.length params) (List.length args))
      end;
      let body_env = List.fold_left2 (fun scope param argument ->
        Environment.extend scope param argument) !closure_env params args in
      eval_machine body body_env k
  | VClosure { fn_name; params; body; env = closure_env;
               closure_kind = Node } ->
      Evaluator_node.apply ~force ~fn_name ~params ~body ~closure_env args
        (continue k)
  | VBuiltin (_, implementation) -> continue k (implementation args env)
  | _ ->
      failwith (Printf.sprintf "not a function: %s"
                  (Presentation.string_of_value fn))
(* ---- Public API ---- *)

let eval_expressions (exprs : expr list) (env : env ref) : value =
  Evaluator_forms.expressions { eval; eval_tail; force } exprs env

let eval_expressions_list (exprs : expr list) (env : env ref) : value list =
  Evaluator_forms.expressions_list { eval; eval_tail; force } exprs env

let perform_effect name args =
  Evaluator_effects.perform ~application:apply name args


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
  match Node.lookup_hit ~key
          ~authorized:(Observation.authorized_id
                         (Evaluator_thunks.captured_capabilities t)) t with
  | Some _ -> true
  | None -> false

let operations = {
  Evaluator_ops.core = { force; eval; apply };
  node = {
    key_of = node_key_of;
    run_body = (fun ~key ~run thunk -> Node.rebuild ~key ~run thunk);
    resolve_hit = resolve_if_hit;
  };
}

let init session ~retain_thunks =
  Session.begin_evaluation ~retain_thunks session
