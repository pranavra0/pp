open Pp_frontend
open Pp_kernel
open Core_model

type operations = {
  eval : expr -> env -> value;
  eval_tail : expr -> env -> (value -> value) -> value;
  force : value -> value;
}

type scope = {
  env : env ref;
  value_defs : (string, value) Hashtbl.t;
}

type definition = {
  name : string;
  params : string list;
  body : expr;
  kind : closure_kind;
}

let unwrap = function
  | ELocated (_, inner) -> inner
  | expr -> expr

let definition_of_expr expr =
  match unwrap expr with
  | EDef (name, params, body) ->
      Some { name; params; body; kind = Function }
  | EDefNode (name, params, body) ->
      Some { name; params; body; kind = Node }
  | _ -> None

let expand_toplevel operations exprs =
  Macro.expand_toplevel_list
    { Macro.eval = operations.eval;
      force_deep = Force_deep.force_deep;
      initial_env = Primitives.initial_env }
    exprs

let read_forms operations path contents =
  Reader_braces.read_dispatch ~source:path ~path contents
  |> expand_toplevel operations

let prebind (env : env ref) (exprs : expr list) : scope =
  let value_defs = Hashtbl.create 8 in
  List.iter (fun expr ->
    match definition_of_expr expr with
    | Some { name; params; body; kind } ->
        let closure = Environment.make_definition ~name ~kind params body env in
        env := Environment.extend !env name closure
    | None ->
        (match unwrap expr with
         | EDefValue (name, _) ->
             let poison = Evaluator_thunks.poison name !env in
             Hashtbl.replace value_defs name poison;
             env := Environment.extend !env name poison
         | _ -> ())) exprs;
  { env; value_defs }

let activate_value scope name value =
  (match Hashtbl.find_opt scope.value_defs name with
   | Some (VThunk poison) -> poison.thunk_status <- Evaluated value
   | Some _ -> ()
   | None -> ());
  scope.env := Environment.extend !(scope.env) name value

let definition_value scope name =
  match Environment.lookup !(scope.env) name with
  | Some value -> value
  | None -> failwith ("definition disappeared: " ^ name)

let merge_module scope bindings =
  scope.env := List.fold_left
    (fun env (name, value) -> Environment.extend env name value)
    !(scope.env) bindings

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
  match List.rev (expressions_list operations exprs env) with
  | value :: _ -> value
  | [] -> VNil

and expressions_list operations exprs env =
  let scope = prebind env exprs in
  let step expr =
    Error_context.with_form_location expr (fun () ->
      match unwrap expr with
      | EDef (name, _, _) | EDefNode (name, _, _) ->
          definition_value scope name
      | EDefValue (name, rhs) ->
          let value = operations.eval rhs !(scope.env) in
          activate_value scope name value;
          value
      | EImport _ ->
          let module_value = operations.force (operations.eval expr !(scope.env)) in
          (match module_value with
           | VEnvMap bindings -> merge_module scope bindings; module_value
           | _ -> failwith "import expects a module value")
      | ELoad path ->
          let contents = Loader.read path in
          expressions operations (read_forms operations path contents) scope.env
      | _ ->
          let result = operations.force (operations.eval expr !(scope.env)) in
          (match result with
           | VEnvMap bindings -> merge_module scope bindings; result
           | _ -> result))
  in
  let rec loop = function
    | [] -> []
    | expr :: rest ->
        let value = step expr in
        value :: loop rest
  in
  loop exprs

and do_block operations exprs env k =
  let env_ref = ref env in
  let scope = prebind env_ref exprs in
  let eval_value name rhs =
    let value = operations.eval rhs !(scope.env) in
    activate_value scope name value;
    value
  in
  let rec loop = function
    | [] -> k VNil
    | EDef (name, _, _) :: rest
    | EDefNode (name, _, _) :: rest ->
        ignore (definition_value scope name);
        loop rest
    | EDefValue (name, rhs) :: rest ->
        ignore (eval_value name rhs);
        loop rest
    | [expr] -> operations.eval_tail expr !(scope.env) k
    | EImport module_expr :: rest ->
        let module_value = operations.force (operations.eval module_expr !(scope.env)) in
        (match module_value with
         | VEnvMap bindings -> merge_module scope bindings; loop rest
         | _ -> failwith "import expects a module value")
    | ELoad path :: rest ->
        let contents = Loader.read path in
        ignore (expressions operations (read_forms operations path contents) scope.env);
        loop rest
    | ELoadModule path :: rest ->
        (match module_file operations path with
         | VEnvMap bindings -> merge_module scope bindings; loop rest
         | _ -> loop rest)
    | expr :: rest ->
        let result = operations.force (operations.eval expr !(scope.env)) in
        (match result with
         | VEnvMap bindings -> merge_module scope bindings
         | _ -> ());
        loop rest
  in
  match exprs with
  | [EDefValue (name, rhs)] -> k (eval_value name rhs)
  | [EDef (name, _, _) | EDefNode (name, _, _)] ->
      k (definition_value scope name)
  | _ -> loop exprs

let module_expr operations body_exprs =
  let base_env = Primitives.initial_env () in
  let env_ref = ref base_env in
  let scope = prebind env_ref body_exprs in
  List.iter (fun expr ->
    match unwrap expr with
    | EDef (name, _, _) | EDefNode (name, _, _) ->
        ignore (definition_value scope name)
    | EDefValue (name, rhs) ->
        let value = operations.eval rhs !(scope.env) in
        activate_value scope name value;
        ()
    | EImport module_expr ->
        let module_value = operations.force (operations.eval module_expr !(scope.env)) in
        (match module_value with
         | VEnvMap bindings -> merge_module scope bindings
         | _ -> failwith "import within module expects a module value")
    | _ ->
        ignore (operations.force (operations.eval expr !(scope.env))))
    body_exprs;
  let final_env = !(scope.env) in
  VEnvMap
    (Evaluator_thunks.new_bindings ~dedup:true
       ~base:base_env.bindings final_env.bindings)
