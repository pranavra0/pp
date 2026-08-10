open Pp_kernel
(* pp evaluator — strict call-by-value evaluation on one heap-continuation
   machine; thunks are used for delayed bindings and persistent nodes. *)

open Core_model

let make_thunk_ca = Evaluator_thunks.make
let make_thunk_ca_typed = Evaluator_thunks.make_typed
type continuation =
  | Stop
  | Callback of (value -> value)
  | Force of continuation
  | Branch of expr * expr * env * continuation
  | Config of expr option * env * continuation
  | Match of (pattern * expr option * expr) list * env * continuation
  | Apply_function of expr list * env * continuation
  | Apply_argument of value * expr list * value list * env * continuation


(* ---- Force: evaluate a thunk on demand ---- *)

let session () = Effect.perform Dynamic_scope.Get_session

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

let persistent_stale (t : thunk) (result : value) =
  match t.thunk_kind, Session.node_key (session ()) t with
  | Persistent _, Some key ->
      Stabilize.evaluated_dependencies_changed ~key ~result
  | _ -> false

let record_persistent_force t =
  if Evaluator_thunks.is_persistent t then
    Option.iter (fun id ->
      Effect.perform (Dynamic_scope.Record_node_force id)) t.thunk_hash

let rec force (v : value) : value =
  let work = Queue.create () in
  Queue.push v work;
  let rec run () =
    match Queue.take_opt work with
    | None -> failwith "force machine: empty work queue"
    | Some (VThunk t) ->
        let result =
          match t.thunk_status with
          | Evaluating -> force_cycle t
          | Evaluated result when not (persistent_stale t result) ->
              record_persistent_force t;
              result
          | Evaluated _ ->
              t.thunk_status <- Unevaluated;
              force_persistent t
          | Unevaluated ->
              if Evaluator_thunks.is_persistent t then force_persistent t
              else force_ephemeral t
        in
        Queue.push result work;
        run ()
    | Some value -> value
  in
  run ()

and force_persistent (t : thunk) : value =
  with_force_frame t (fun () ->
    let key = node_key_of t in
    let run_body () = eval t.thunk_expr t.thunk_env in
    Evaluator_node.force ~key ~data_closed:(is_data_closed t)
      ~run:run_body t)

and force_ephemeral (t : thunk) : value =
  t.thunk_status <- Evaluating;
  try
    let result = with_force_frame t (fun () ->
      eval t.thunk_expr t.thunk_env) in
    Node.enforce_type t result;
    t.thunk_status <- Evaluated result;
    result
  with exn ->
    t.thunk_status <- Unevaluated;
    raise exn

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
  key
(* Remote placement accepts a node only when its forced free variables are
   data encodable; builtin primitives are resolved by the identical runtime. *)
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

(* The evaluator is one heap-continuation machine.  [eval_tail] is the
   callback-shaped adapter required by helper modules; [Callback] lets it
   attach the caller's continuation to the same machine rather than starting
   a second evaluation. *)
and eval (e : expr) (env : env) : value =
  eval_machine e env Stop

and eval_tail (e : expr) (env : env) (k : value -> value) : value =
  eval_machine e env (Callback k)


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
      Evaluator_forms.do_block { eval; eval_tail; force }
        expressions env (continue k)
  | EWithCaps (capability, body) ->
      Evaluator_scope.with_caps { eval; eval_tail; force; apply }
        capability body env (continue k)
  | EPerform (name, arguments) ->
      let values = List.map (fun argument -> make_thunk_ca argument env) arguments
                   |> List.map force in
      continue k (Evaluator_effects.perform ~application:apply name values)
  | EWithHandler (handlers, body) ->
      Evaluator_scope.with_handlers { eval; eval_tail; force; apply }
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
      Evaluator_scope.with_config { eval; eval_tail; force; apply }
        config body env (continue k)
  | EConfig (key, default) ->
      eval_machine key env (Force (Config (default, env, k)))
  | EMatch (scrutinee, arms) ->
      eval_machine scrutinee env (Force (Match (arms, env, k)))

and apply (fn : value) (args : value list) (env : env) : value =
  Evaluator_application.apply { eval_tail; force } fn args env

and continue (k : continuation) (value : value) : value =
  match k with
  | Stop -> value
  | Callback callback -> callback value
  | Force rest -> continue rest (force value)
  | Branch (yes, no, env, rest) ->
      (match value with
       | VBool false | VNil -> eval_machine no env rest
       | _ -> eval_machine yes env rest)
  | Config (default, env, rest) ->
      let name = match value with
        | VString value | VKeyword value | VSymbol value -> value
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      Evaluator_scope.read_config { eval; eval_tail; force; apply }
        name default env (continue rest)
  | Match (arms, env, rest) ->
      Evaluator_match.eval ~force ~eval ~eval_tail value arms env
        (continue rest)
  | Apply_function (arguments, env, rest) ->
      (match arguments with
       | [] ->
           Evaluator_application.apply_tail { eval_tail; force }
             value [] env (continue rest)
       | argument :: remaining ->
           eval_machine argument env
             (Force (Apply_argument (value, remaining, [], env, rest))))
  | Apply_argument (fn, [], reversed, env, rest) ->
      Evaluator_application.apply_tail { eval_tail; force }
        fn (List.rev (value :: reversed)) env (continue rest)
  | Apply_argument (fn, argument :: remaining, reversed, env, rest) ->
      eval_machine argument env
        (Force (Apply_argument (fn, remaining, value :: reversed, env, rest)))
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
    data_closed = is_data_closed;
  };
}

let init session ~retain_thunks =
  Session.begin_evaluation ~retain_thunks session
