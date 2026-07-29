open Pp_kernel

let check condition message = if not condition then failwith message

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
  let map_left = Value.map [
    Core_model.VKeyword "b", Core_model.VInt 2;
    Core_model.VKeyword "a", Core_model.VInt 1;
  ] in
  let map_right = Value.map [
    Core_model.VKeyword "a", Core_model.VInt 1;
    Core_model.VKeyword "b", Core_model.VInt 2;
  ] in
  check (Identity.equal_value map_left map_right)
    "map identity depends on input order";
  let duplicate = Value.map [
    Core_model.VKeyword "a", Core_model.VInt 1;
    Core_model.VKeyword "a", Core_model.VInt 2;
  ] in
  (match duplicate with
   | Core_model.VMap [_, value] ->
       check (Identity.equal_value value (Core_model.VInt 2))
         "map did not retain the rightmost duplicate"
   | _ -> failwith "map did not remove duplicate keys");
  (match Value.set [Core_model.VInt 2; Core_model.VInt 1; Core_model.VInt 2] with
   | Core_model.VSet values ->
       let hashes = List.map Identity.hash_value values in
       check (List.length values = 2) "set did not remove duplicates";
       check (hashes = List.sort String.compare hashes)
         "set elements are not in identity order"
   | _ -> assert false);
  let tagged_with_extra =
    Core_model.VPair (Core_model.VKeyword "ok",
      Core_model.VPair (Core_model.VInt 1,
        Core_model.VPair (Core_model.VInt 2, Core_model.VNil)))
  in
  check (Pattern_match.match_pattern tagged_with_extra
           (Core_model.PTagged ("ok", [Core_model.PVariable "value"])) = None)
    "tagged pattern accepted trailing values";
  print_endline "kernel: ok"
