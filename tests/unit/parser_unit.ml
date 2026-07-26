open Pp_kernel
open Pp_frontend

let check condition message = if not condition then failwith message

let () =
  let sexpr = Reader.read_string "(if true 1 2)" in
  let braces = Reader_braces.read_string "if true { 1 } else { 2 }" in
  check (List.length sexpr = 1 && List.length braces = 1) "reader form count changed";
  check (Identity.hash_expr (List.hd sexpr) = Identity.hash_expr (List.hd braces))
    "the two readers produced different AST identity";
  let sexpr_text = Printer_sexpr.print_program sexpr in
  check (List.length (Reader.read_string sexpr_text) = 1) "sexpr printer did not re-read";
  let brace_text = Printer_braces.print_program braces in
  check (List.length (Reader_braces.read_string brace_text) = 1)
    "brace printer did not re-read";
  let located = List.hd (Reader.read_string ~source:"range.ppl" "(print 1)") in
  let range = match located with
    | Core_model.ELocated (range, _) -> range
    | _ -> failwith "reader did not attach a source range" in
  check ((Source_range.start range).offset = 0
         && (Source_range.end_ range).offset = 1
         && (Source_range.start range).line = 1
         && (Source_range.start range).column = 1)
    "reader source range is not token-precise";
  let diagnostic = Source_error.diagnostic ~code:"test-error" ~location:range "bad" in
  let lsp = Source_error.to_lsp diagnostic in
  check (lsp.code = Some "test-error"
         && Option.map (fun (r : Source_error.lsp_range) ->
              r.start.line = 0 && r.start.character = 0)
              lsp.range = Some true)
    "structured diagnostic did not convert to LSP coordinates";
  print_endline "parser: ok"
