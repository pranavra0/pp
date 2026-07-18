open Core_model

type operations = {
  eval : expr -> env -> value;
  eval_tail : expr -> env -> (value -> value) -> value;
  force : value -> value;
}

let expand_toplevel operations exprs =
  Macro.expand_toplevel_list
    { Macro.eval = operations.eval;
      force_deep = Force_deep.force_deep;
      initial_env = Primitives.initial_env }
    exprs

let read_forms operations path contents =
  Reader_braces.read_dispatch ~source:path ~path contents
  |> expand_toplevel operations

let rec module_file operations path =
  let source = Loader.read path in
  let exprs =
    Reader_braces.read_dispatch ~path source
    |> expand_toplevel operations
  in
  let base_env = Primitives.initial_env () in
  let module_env = ref base_env in
  ignore (expressions operations exprs module_env);
  VEnvMap
    (Evaluator_thunks.new_bindings
       ~base:base_env.bindings !module_env.bindings)

and load operations path env =
  let contents = Loader.read path in
  expressions operations (read_forms operations path contents) (ref env)

and expressions operations exprs env =
  let unwrap expr =
    match expr with
    | ELocated (_, inner) -> inner
    | _ -> expr
  in
  let step expr =
    Error_context.with_form_location expr (fun () ->
      match unwrap expr with
      | EDef (name, params, body) ->
          let closure = Environment.make_closure ~name:(Some name) params body env in
          env := Environment.extend !env name closure;
          closure
      | EDefNode (name, params, body) ->
          let closure = Environment.make_closure ~name:(Some name) params body env in
          env := Environment.extend !env name closure;
          closure
      | EDefValue (name, rhs) ->
          let value = operations.eval rhs !env in
          env := Environment.extend !env name value;
          value
      | EImport _ ->
          let module_value = operations.force (operations.eval expr !env) in
          (match module_value with
           | VEnvMap bindings ->
               env := List.fold_left
                 (fun env (name, value) -> Environment.extend env name value)
                 !env bindings;
               module_value
           | _ -> failwith "import expects a module value")
      | ELoad path ->
          let contents = Loader.read path in
          expressions operations (read_forms operations path contents) env
      | _ ->
          let result = operations.force (operations.eval expr !env) in
          (match result with
           | VEnvMap bindings ->
               env := List.fold_left
                 (fun env (name, value) -> Environment.extend env name value)
                 !env bindings;
               result
           | _ -> result))
  in
  let rec loop = function
    | [] -> VNil
    | [expr] -> step expr
    | expr :: rest -> ignore (step expr); loop rest
  in
  loop exprs

and do_block operations exprs env k =
  let env_ref = ref env in
  let poisons = Hashtbl.create 4 in
  List.iter (function
    | EDefValue (name, _) ->
        let poison = Evaluator_thunks.poison name !env_ref in
        Hashtbl.replace poisons name poison;
        env_ref := Environment.extend !env_ref name poison
    | _ -> ()) exprs;
  let rec loop = function
    | [] -> k VNil
    | [last] -> operations.eval_tail last !env_ref k
    | EDef (name, params, body) :: rest ->
        let closure = Environment.make_closure ~name:(Some name) params body env_ref in
        env_ref := Environment.extend !env_ref name closure;
        loop rest
    | EDefNode (name, params, body) :: rest ->
        let closure = Environment.make_closure ~name:(Some name) params body env_ref in
        env_ref := Environment.extend !env_ref name closure;
        loop rest
    | EDefValue (name, rhs) :: rest ->
        let value = operations.eval rhs !env_ref in
        (match Hashtbl.find_opt poisons name with
         | Some (VThunk thunk) -> thunk.thunk_status <- Evaluated value
         | _ -> ());
        env_ref := Environment.extend !env_ref name value;
        loop rest
    | EImport module_expr :: rest ->
        let module_value = operations.force (operations.eval module_expr !env_ref) in
        (match module_value with
         | VEnvMap bindings ->
             env_ref := List.fold_left
               (fun env (name, value) -> Environment.extend env name value)
               !env_ref bindings;
             loop rest
         | _ -> failwith "import expects a module value")
    | ELoad path :: rest ->
        let contents = Loader.read path in
        ignore (expressions operations (read_forms operations path contents) env_ref);
        loop rest
    | ELoadModule path :: rest ->
        (match module_file operations path with
         | VEnvMap bindings ->
             env_ref := List.fold_left
               (fun env (name, value) -> Environment.extend env name value)
               !env_ref bindings;
             loop rest
         | _ -> loop rest)
    | expr :: rest ->
        let result = operations.force (operations.eval expr !env_ref) in
        (match result with
         | VEnvMap bindings ->
             env_ref := List.fold_left
               (fun env (name, value) -> Environment.extend env name value)
               !env_ref bindings
         | _ -> ());
        loop rest
  in
  loop exprs

let module_expr operations body_exprs =
  let base_env = Primitives.initial_env () in
  let poisons = Hashtbl.create 4 in
  let prebound_env = List.fold_left (fun env expr ->
    match expr with
    | EDefValue (name, _) ->
        let poison = Evaluator_thunks.poison name env in
        Hashtbl.replace poisons name poison;
        Environment.extend env name poison
    | _ -> env
  ) base_env body_exprs in
  let final_env = List.fold_left (fun env expr ->
    match expr with
    | EDef (name, params, body) | EDefNode (name, params, body) ->
        let closure = Environment.make_closure ~name:(Some name) params body (ref env) in
        Environment.extend env name closure
    | EDefValue (name, rhs) ->
        let value = operations.eval rhs env in
        (match Hashtbl.find_opt poisons name with
         | Some (VThunk thunk) -> thunk.thunk_status <- Evaluated value
         | _ -> ());
        Environment.extend env name value
    | EImport module_expr ->
        let module_value = operations.force (operations.eval module_expr env) in
        (match module_value with
         | VEnvMap bindings ->
             List.fold_left
               (fun env (name, value) -> Environment.extend env name value)
               env bindings
         | _ -> failwith "import within module expects a module value")
    | _ ->
        ignore (operations.force (operations.eval expr env));
        env
  ) prebound_env body_exprs in
  VEnvMap
    (Evaluator_thunks.new_bindings ~dedup:true
       ~base:base_env.bindings final_env.bindings)
