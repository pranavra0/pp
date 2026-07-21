open Pp_kernel

let check condition message = if not condition then failwith message

let () =
  let one = Core_model.EApply (Core_model.ESymbol "f", [Core_model.ELiteral (Core_model.VInt 1)]) in
  let two = Core_model.EApply (Core_model.ESymbol "f", [Core_model.ELiteral (Core_model.VInt 2)]) in
  check (Identity.hash_expr one <> Identity.hash_expr two) "expression hashes collided";
  let quoted = Quotation.quote_to_value one in
  let reified = Quotation.value_to_expr quoted in
  check (Identity.hash_expr one = Identity.hash_expr reified) "quote conversion drifted";
  let key = Identity_types.Node_key.make
      ~argument_hashes:[] ~code_hash:(Identity.hash_expr one)
      ~free_variable_hashes:["free"] in
  check (Identity_types.Node_key.to_string key =
         Identity_types.Node_key.to_string
           (Identity_types.Node_key.of_string (Identity_types.Node_key.to_string key)))
    "node key text did not round-trip";
  check (Hasher.hash_concat ["a:b"; "c"] <> Hasher.hash_concat ["a"; "b:c"])
    "hash framing is ambiguous";
  print_endline "kernel: ok"
