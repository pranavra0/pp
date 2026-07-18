open Core_model

let make_with_hash ~tag (expr : expr) (type_ann : expr option)
    (loc : (string * int) option) (env : env) : value =
  let caps = Effect.perform Dynamic_scope.Get_capabilities in
  let cfg = Effect.perform Dynamic_scope.Get_config in
  let handlers = Effect.perform Dynamic_scope.Get_handlers in
  let caps_hash = Hasher.hash_concat ("caps" :: List.map Capability.hash caps) in
  let cfg_hash = Hasher.hash_concat ("cfg" :: List.map Identity.hash_value cfg) in
  let handlers_hash =
    Hasher.hash_concat ("handlers" :: List.concat_map (fun (n, h) -> [n; h]) handlers)
  in
  let expr_hash = Identity.hash_expr expr in
  let type_hash =
    match type_ann with
    | None -> []
    | Some ty -> [Identity.hash_expr ty]
  in
  let hash = Hasher.hash_concat
      (tag :: expr_hash :: type_hash @ [env.env_hash; caps_hash; cfg_hash; handlers_hash])
  in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_thunk session hash with
  | Some existing -> VThunk existing
  | None ->
      let thunk = {
        thunk_status = Unevaluated;
        thunk_hash = Some hash;
        thunk_expr = expr;
        thunk_env = env;
        type_ann;
        thunk_loc = loc;
        config_hash = cfg_hash;
        thunk_persist = false;
        node_caps = [];
      } in
      Session.add_thunk session hash thunk;
      VThunk thunk

let make expr env = make_with_hash ~tag:"thunk" expr None None env

let make_typed expr ty loc env =
  make_with_hash ~tag:"thunk-typed" expr (Some ty) loc env

let poison_expr (name : string) : expr =
  EApply (ESymbol "error",
          [ELiteral (VString (name ^ ": referenced before its definition"))])

let poison name env = Environment.make_thunk (poison_expr name) env

let new_bindings ?(dedup = false) ~(base : (string * value) list)
    (bindings : (string * value) list) : (string * value) list =
  let rec collect all acc =
    match all with
    | [] -> List.rev acc
    | (name, value) :: rest ->
        if List.exists (fun (base_name, _) -> base_name = name) base
           || (dedup && List.exists (fun (added_name, _) -> added_name = name) acc) then
          collect rest acc
        else
          collect rest ((name, value) :: acc)
  in
  collect bindings []
