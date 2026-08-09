open Pp_kernel

let check condition message = if not condition then failwith message
let () =
  check (Sys.int_size = 63) "kernel requires 63-bit OCaml ints";
  List.iter (fun n ->
    let value = Core_model.VInt n in
    check (Codec.decode_value (Option.get (Codec.encode_value value)) = Some value)
      "integer boundary did not round-trip")
    [-(1 lsl 62); (1 lsl 62) - 1]

let () =
  let one = Core_model.EApply (Core_model.ESymbol "f", [Core_model.ELiteral (Core_model.VInt 1)]) in
  let two = Core_model.EApply (Core_model.ESymbol "f", [Core_model.ELiteral (Core_model.VInt 2)]) in
  check (Identity.hash_expr one <> Identity.hash_expr two) "expression hashes collided";
  let quoted = Quotation.quote_to_value one in
  let reified = Quotation.value_to_expr quoted in
  check (Identity.hash_expr one = Identity.hash_expr reified) "quote conversion drifted";
  let key = Identity.node_key ~code:one
      ~free_variables:[("free", Some (Core_model.VInt 1))]
      ~argument_values:[] in
  check (Identity_types.Node_key.to_string key =
         Identity_types.Node_key.to_string
           (Identity_types.Node_key.of_string (Identity_types.Node_key.to_string key)))
    "node key text did not round-trip";
  check (Hasher.hash_concat ["a:b"; "c"] <> Hasher.hash_concat ["a"; "b:c"])
    "hash framing is ambiguous";
  let open Core_model in
  let map_a = VMap [VString "z", VInt 1; VString "a", VInt 2] in
  let map_b = VMap [VString "a", VInt 2; VString "z", VInt 1] in
  check (Identity.equal_value map_a map_b)
    "map equality depended on insertion order";
  check (Codec.encode_value map_a = Codec.encode_value map_b)
    "map encoding depended on insertion order";
  let map_duplicate =
    Identity.canonical_map_entries
      [VString "key", VInt 1; VString "key", VInt 2]
  in
  check (map_duplicate = [VString "key", VInt 2])
    "map duplicate precedence was not rightmost";
  let set =
    Identity.canonical_set_elements [VString "z"; VString "a"; VString "z"]
  in
  check (List.length set = 2)
    "set canonicalization retained duplicate content";
  check
    (Codec.decode_value (Option.get (Codec.encode_value (VSet set))) =
     Some (VSet set))
    "set codec round-trip changed canonical order";
  let signed_zero_map =
    Identity.canonical_map_entries
      [VFloat 0.0, VInt 1; VFloat (-0.0), VInt 2]
  in
  check (List.length signed_zero_map = 2)
    "map canonicalization collapsed signed-zero keys";
  let signed_zero_keys = List.map fst signed_zero_map in
  let positive_zero_text = Presentation.string_of_value (VFloat 0.0) in
  let negative_zero_text = Presentation.string_of_value (VFloat (-0.0)) in
  check (positive_zero_text <> negative_zero_text)
    "presentation did not distinguish signed zeros";
  check
    (List.exists (fun key -> Presentation.string_of_value key = positive_zero_text) signed_zero_keys &&
     List.exists (fun key -> Presentation.string_of_value key = negative_zero_text) signed_zero_keys)
    "map canonicalization did not retain both signed-zero keys";
  check (Identity.hash_value (VFloat 0.0) <> Identity.hash_value (VFloat (-0.0)))
    "signed-zero hashes were aliased";
  check (not (Identity.equal_value (VFloat 0.0) (VFloat (-0.0))))
    "signed-zero values were equal";
  let signed_zero_set =
    Identity.canonical_set_elements [VFloat 0.0; VFloat (-0.0); VFloat 1.0]
  in
  check (List.length signed_zero_set = 3)
    "set canonicalization collapsed signed-zero elements";
  let one_text = Presentation.string_of_value (VFloat 1.0) in
  check
    (List.exists (fun value -> Presentation.string_of_value value = positive_zero_text) signed_zero_set &&
     List.exists (fun value -> Presentation.string_of_value value = negative_zero_text) signed_zero_set &&
     List.exists (fun value -> Presentation.string_of_value value = one_text) signed_zero_set)
    "set canonicalization did not retain +0, -0, and 1";
  let sequential =
    ELetStar
      (["x", ESymbol "outer"; "y", ESymbol "x"], ESymbol "y")
  in
  check (Free_vars.SS.elements (Free_vars.free_vars sequential) = ["outer"])
    "let* free-variable analysis hid an outer dependency";
  let mutual =
    ELet
      (["x", ELiteral (VInt 1); "y", ESymbol "x"], ESymbol "y")
  in
  check (Free_vars.SS.elements (Free_vars.free_vars mutual) = [])
    "let free-variable analysis did not use the complete binding set";
  let shadowed_outer =
    EFn (["x"],
      ELet
        (["x", ELiteral (VInt 1); "y", ESymbol "x"], ESymbol "y"))
  in
  check (Free_vars.SS.elements (Free_vars.free_vars shadowed_outer) = [])
    "mutual let binding leaked an outer shadowed name";
  let cross_arm_match =
    EMatch
      (ELiteral (VInt 0),
       [ (PVariable "x", None, ELiteral (VInt 1));
         (PWildcard, None, ESymbol "x") ])
  in
  check
    (Free_vars.SS.elements (Free_vars.free_vars cross_arm_match) = ["x"])
    "match free-variable analysis leaked a binder across arms";
  let captured_x value =
    Identity.node_key ~code:cross_arm_match
      ~free_variables:[("x", Some (VInt value))] ~argument_values:[]
  in
  check (captured_x 1 <> captured_x 2)
    "match ambient free variable did not affect node capture";
  let explicit_caps =
    EWithCaps
      (ESymbol "caps",
       EApply (ESymbol "slurp", [ELiteral (VString "input")]))
  in
  check
    (Free_vars.SS.elements (Free_vars.node_free_vars explicit_caps) =
     ["caps"; "slurp"])
    "node free-variable analysis hid an explicit capability value";
  let rec cyclic = VPair (VInt 1, cyclic) in
  check (Identity.equal_value cyclic cyclic)
    "content equality did not terminate on a cyclic value";
  let typed_thunk_at ~line ~column =
    VThunk
      { thunk_status = Unevaluated;
        thunk_hash = None;
        thunk_expr = ELiteral (VInt 7);
        thunk_env = { env_id = 0; env_hash = "env"; bindings = [] };
        thunk_name = None;
        type_ann = Some (ESymbol "Int");
        thunk_loc =
          Some (Source_range.point ~source:"test.pp" ~offset:0 ~line ~column);
        config_hash = "config";
        thunk_kind = Ephemeral }
  in
  check
    (Identity.hash_value (typed_thunk_at ~line:10 ~column:1) <>
     Identity.hash_value (typed_thunk_at ~line:11 ~column:1))
    "thunk identity omitted its source line";
  check
    (Identity.hash_value (typed_thunk_at ~line:10 ~column:1) =
     Identity.hash_value (typed_thunk_at ~line:10 ~column:99))
    "thunk identity was perturbed by source column";
  check
    (Identity.hash_value (typed_thunk_at ~line:10 ~column:1) =
     Identity.hash_value (typed_thunk_at ~line:10 ~column:1))
    "thunk identity was not deterministic";
  let located_at line =
    ELocated
      (Source_range.point ~source:"test.pp" ~offset:line ~line ~column:1,
       ELiteral (VInt 1))
  in
  check
    (Identity.hash_expr (located_at 1) <> Identity.hash_expr (located_at 2))
    "expression identity omitted an observable source line";
  print_endline "kernel: ok"
