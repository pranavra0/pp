(* pp main — entry point for the pp interpreter *)

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  match args with
  | [] ->
      (* No arguments: start REPL *)
      Repl.repl ()
  | ["--version"] | ["-v"] ->
      Printf.printf "pp v0.1.0\n"
  | ["--help"] | ["-h"] ->
      Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\n";
      Printf.printf "Usage:\n";
      Printf.printf "  pp              Start REPL\n";
      Printf.printf "  pp <file.pp>    Run a pp source file\n";
      Printf.printf "  pp run <file>   Run a pp source file\n";
      Printf.printf "  pp --version    Print version\n";
      Printf.printf "  pp --help       Print this help\n"
  | ["run"; filename] ->
      ignore (Repl.execute_file filename)
  | [filename] ->
      (* Run a file *)
      ignore (Repl.execute_file filename)
  | _ ->
      Printf.eprintf "Unknown arguments. Use 'pp --help' for usage.\n";
      exit 1
