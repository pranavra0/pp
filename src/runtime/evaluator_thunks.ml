open Pp_kernel
open Core_model

let make_with_hash ?name ?(kind = Ephemeral) ~tag (expr : expr)
    (type_ann : expr option) (loc : Source_range.t option) (env : env) : value =
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
  let location_hash =
    match loc with
    | None -> []
    | Some range ->
        let position = Source_range.start range in
        [Hasher.hash_concat
           ["location"; Source_range.source range;
            string_of_int position.line]]
  in
  let argument_values = match kind with
    | Ephemeral -> []
    | Persistent { argument_values; _ } -> argument_values
  in
  let arg_hashes = List.map (fun value -> Hasher.hash_concat ["arg"; Identity.hash_value value])
      argument_values
  in
  let hash = Hasher.hash_concat
      (tag :: expr_hash :: type_hash @ location_hash @ arg_hashes @
       [env.env_hash; caps_hash; cfg_hash; handlers_hash])
  in
  let make_fresh () =
    VThunk {
      thunk_status = Unevaluated;
      thunk_hash = Some hash;
      thunk_expr = expr;
      thunk_env = env;
      thunk_name = name;
      type_ann;
      thunk_loc = loc;
      config_hash = cfg_hash;
      thunk_kind = kind;
    }
  in
  match kind with
  | Ephemeral -> make_fresh ()
  | Persistent _ ->
      let session = Effect.perform Dynamic_scope.Get_session in
      (match Session.find_thunk session hash with
       | Some existing -> VThunk existing
       | None ->
           let thunk = make_fresh () in
           (match thunk with
            | VThunk thunk -> Session.add_thunk session hash thunk
            | _ -> assert false);
           thunk)

let make ?name expr env = make_with_hash ?name ~tag:"thunk" expr None None env

let make_node ?name expr env ~arguments =
  let captured_caps = Effect.perform Dynamic_scope.Get_capabilities in
  make_with_hash ?name
    ~kind:(Persistent { captured_caps; argument_values = arguments })
    ~tag:"node-thunk" expr None None env

let is_persistent (t : thunk) =
  match t.thunk_kind with
  | Persistent _ -> true
  | Ephemeral -> false

let captured_capabilities (t : thunk) =
  match t.thunk_kind with
  | Persistent { captured_caps; _ } -> captured_caps
  | Ephemeral -> []

let argument_values (t : thunk) =
  match t.thunk_kind with
  | Persistent { argument_values; _ } -> argument_values
  | Ephemeral -> []

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
