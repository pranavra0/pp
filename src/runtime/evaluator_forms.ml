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


let source_of_expr = function
  | ELocated (loc, _) -> Some (Source_range.source loc)
  | _ -> None
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

let read_forms _operations path contents =
  Reader_braces.read_dispatch ~source:path ~path contents

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
  List.iter (fun (name, _) ->
    if Option.is_some (Environment.lookup !(scope.env) name) then
      failwith ("import collision: " ^ name))
    bindings;
  scope.env := List.fold_left
    (fun env (name, value) -> Environment.extend env name value)
    !(scope.env) bindings

let exported_bindings (scope : scope) (defined : (string, unit) Hashtbl.t)
    ~(is_macro : string -> bool) (names : string list) : (string * value) list =
  let seen = Hashtbl.create (List.length names) in
  List.filter_map (fun name ->
    if Hashtbl.mem seen name then
      failwith ("duplicate export: " ^ name);
    Hashtbl.add seen name ();
    let runtime_defined = Hashtbl.mem defined name in
    let macro_defined = is_macro name in
    if runtime_defined && macro_defined then
      failwith ("module exports both runtime and macro name: " ^ name);
    if macro_defined then None
    else if not runtime_defined then
      failwith ("export name is not defined by module: " ^ name)
    else
      match Environment.lookup !(scope.env) name with
      | Some value -> Some (name, value)
      | None -> failwith ("export name is not defined by module: " ^ name))
    names

let record_export export_names names =
  match !export_names with
  | Some _ -> failwith "module has more than one export declaration"
  | None ->
      if names = [] then failwith "export requires at least one name";
      export_names := Some names

let rec module_file operations path =
  let resolved = Loader.resolve path in
  let source = Loader.read resolved in
  let exprs, macro_names =
    Macro.expand_module_file
      { Macro.eval = operations.eval;
        force_deep = Force_deep.force_deep;
        initial_env = Primitives.initial_env }
      ~path:resolved source
  in
  module_expr ~macro_names operations exprs

and load operations path env =
  let resolved = Loader.resolve path in
  let contents = Loader.read resolved in
  expressions operations (read_forms operations resolved contents) (ref env)

and expressions operations exprs env =
  let values =
    List.concat_map
      (fun expr ->
        expressions_list operations
          (expand_toplevel operations [expr]) env)
      exprs
  in
  match List.rev values with
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
      | EExport _ ->
          failwith "export is only valid directly in a module body"
      | EImport _ ->
          let module_value = operations.force (operations.eval expr !(scope.env)) in
          (match module_value with
           | VEnvMap bindings -> merge_module scope bindings; module_value
           | _ -> failwith "import expects a module value")
      | ELoad path ->
          let source = source_of_expr expr in
          let resolved = Loader.resolve ?source path in
          let contents = Loader.read resolved in
          expressions operations (read_forms operations resolved contents) scope.env
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
    | EExport _ :: _ ->
        failwith "export is only valid directly in a module body"
    | [expr] -> operations.eval_tail expr !(scope.env) k
    | EImport module_expr :: rest ->
        let module_value = operations.force (operations.eval module_expr !(scope.env)) in
        (match module_value with
         | VEnvMap bindings -> merge_module scope bindings; loop rest
         | _ -> failwith "import expects a module value")
    | ELoad path :: rest ->
        let resolved = Loader.resolve path in
        let contents = Loader.read resolved in
        ignore (expressions operations (read_forms operations resolved contents) scope.env);
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

and module_expr ?(macro_names = []) operations body_exprs =
  let base_env = Primitives.initial_env () in
  let env_ref = ref base_env in
  let scope = prebind env_ref body_exprs in
  let defined = Hashtbl.create 8 in
  List.iter (fun expr ->
    match unwrap expr with
    | EDef (name, _, _) | EDefNode (name, _, _)
    | EDefValue (name, _) ->
        Hashtbl.replace defined name ()
    | _ -> ())
    body_exprs;
  let export_names = ref None in
  List.iter (fun expr ->
    Error_context.with_form_location expr (fun () ->
      match unwrap expr with
      | EExport names ->
          record_export export_names names
      | EDef (name, _, _) | EDefNode (name, _, _) ->
          ignore (definition_value scope name)
      | EDefValue (name, rhs) ->
          let value = operations.eval rhs !(scope.env) in
          activate_value scope name value;
          ()
      | EImport module_expr ->
          let module_value = operations.force (operations.eval module_expr !(scope.env)) in
          (match module_value with
           | VEnvMap bindings ->
               merge_module scope bindings;
               List.iter (fun (name, _) -> Hashtbl.replace defined name ()) bindings
           | _ -> failwith "import within module expects a module value")
      | _ ->
          ignore (operations.force (operations.eval expr !(scope.env)))))
    body_exprs;
  let session = Effect.perform Dynamic_scope.Get_session in
  let local_macro_names =
    Option.value ~default:[]
      (Session.find_module_macro_exports session
         (Identity.hash_expr (EModule body_exprs)))
  in
  let is_macro name =
    List.mem name (macro_names @ local_macro_names) ||
    Option.is_some (Session.find_macro session name)
  in
  match !export_names with
  | None -> VEnvMap []
  | Some names -> VEnvMap (exported_bindings scope defined ~is_macro names)
