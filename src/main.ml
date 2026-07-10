(* pp main — entry point for the pp interpreter *)

let () =
  let args = List.tl (Array.to_list Sys.argv) in
  let bytecode = ref false in
  let diff = ref false in
  let eval_str = ref None in
  let files = ref [] in
  let grants = ref [] in

  let rec parse = function
    | "--bytecode" :: rest -> bytecode := true; parse rest
    | "--diff" :: rest -> diff := true; bytecode := true; parse rest
    | "--update" :: rest -> Island.update_mode := true; parse rest
    | "--grant" :: grant :: rest -> grants := grant :: !grants; parse rest
    | "-e" :: e :: rest -> eval_str := Some e; parse rest
    | "--version" :: _ | "-v" :: _ ->
        Printf.printf "pp v0.1.0\n"; exit 0
    | "--help" :: _ | "-h" :: _ ->
        Printf.printf "pp — lazy, pure-by-default, content-addressed Lisp\n";
        Printf.printf "Usage:\n";
        Printf.printf "  pp                       Start REPL\n";
        Printf.printf "  pp <file.pp>             Run a pp source file\n";
        Printf.printf "  pp --bytecode <file.pp>  Run via bytecode VM\n";
        Printf.printf "  pp --diff <file.pp>      Run both backends and diff\n";
        Printf.printf "  pp -e '<expr>'           Evaluate an expression\n";
        Printf.printf "  pp --grant <spec>        Grant capability (fs:/path:rw, net:tcp, etc.)\n";
        Printf.printf "  pp run <file>            Run a pp source file\n";
        Printf.printf "  pp --version             Print version\n";
        Printf.printf "  pp --help                Print this help\n";
        exit 0
    | "run" :: f :: rest -> files := f :: !files; parse rest
    | f :: rest -> files := f :: !files; parse rest
    | [] -> ()
  in
  parse args;

  (* Parse --grant specs into capabilities *)
  let parse_grant spec =
    match String.split_on_char ':' spec with
    | ["fs"; path; mode] ->
        let m = match mode with
          | "ro" -> Types.Read | "rw" -> Types.ReadWrite | "wo" -> Types.Write
          | _ -> failwith ("invalid fs mode in --grant: " ^ mode)
        in Types.CapFilesystem { path; mode = m }
    | ["net"; protocol] ->
        Types.CapNetwork { protocol }
    | ["process"] ->
        Types.CapProcess
    | _ -> failwith ("invalid --grant spec: " ^ spec)
  in
  let initial_caps = List.map parse_grant (List.rev !grants) in
  Runtime.initial_capabilities := initial_caps;

  match !eval_str, !files with
  | Some e, [] ->
      if !diff then begin
        Printf.eprintf "--diff not supported with -e\n"; exit 1
      end;
      let results = Repl.execute_string_bytecode !bytecode e in
      List.iter (fun v ->
        Printf.printf "%s\n" (Types.string_of_value v)
      ) results
  | None, [] ->
      if !bytecode then Repl.repl_bytecode ()
      else Repl.repl ()
  | _, files ->
      let files = List.rev files in
      if !diff then begin
        List.iter (fun f ->
          let tw_results = Repl.execute_file f in
          let bc_results = Repl.execute_file_bytecode true f in
          let tw_strings = List.map Types.string_of_value tw_results in
          let bc_strings = List.map Types.string_of_value bc_results in
          if tw_strings <> bc_strings then begin
            Printf.eprintf "--diff mismatch in %s\n" f;
            Printf.eprintf "tree-walker (%d values):\n" (List.length tw_strings);
            List.iter (Printf.eprintf "  %s\n") tw_strings;
            Printf.eprintf "bytecode (%d values):\n" (List.length bc_strings);
            List.iter (Printf.eprintf "  %s\n") bc_strings;
            exit 1
          end
        ) files
      end else begin
        List.iter (fun f ->
          ignore (Repl.execute_file_bytecode !bytecode f)
        ) files
      end
