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
  print_endline "parser: ok"
