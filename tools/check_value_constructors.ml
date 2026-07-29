open Parsetree

let constructor_name = function
  | Longident.Lident name -> name
  | Longident.Ldot (_, name) -> name.txt
  | Longident.Lapply _ -> ""

let has_suffix path suffix =
  let path_length = String.length path in
  let suffix_length = String.length suffix in
  path_length >= suffix_length
  && String.equal (String.sub path (path_length - suffix_length) suffix_length) suffix

let source_file path = has_suffix path ".ml"

let rec files path =
  if Sys.is_directory path then
    Sys.readdir path
    |> Array.to_list
    |> List.filter (fun name -> not (String.equal name "_build"))
    |> List.concat_map (fun name -> files (Filename.concat path name))
  else if source_file path then [path]
  else []

let check_file path =
  let channel = open_in_bin path in
  let lexbuf = Lexing.from_channel channel in
  Lexing.set_filename lexbuf path;
  let structure =
    Fun.protect ~finally:(fun () -> close_in_noerr channel)
      (fun () -> Parse.implementation lexbuf)
  in
  let violations = ref [] in
  let iterator =
    { Ast_iterator.default_iterator with
      expr = (fun self expression ->
        (match expression.pexp_desc with
         | Pexp_construct ({ txt = name; loc }, _)
           when List.mem (constructor_name name) ["VMap"; "VSet"] ->
             violations := loc.loc_start.pos_lnum :: !violations
         | _ -> ());
        Ast_iterator.default_iterator.expr self expression) }
  in
  iterator.structure iterator structure;
  List.rev_map (fun line -> path, line) !violations

let () =
  let root =
    match Array.to_list Sys.argv with
    | [_; "--root"; root] -> root
    | _ -> prerr_endline "usage: check_value_constructors --root DIR"; exit 2
  in
  let allowed = ["src/kernel/value.ml"; "src/kernel/codec.ml"] in
  let targets = ["src"; "tools"; "tests/unit"] in
  let violations =
    targets
    |> List.concat_map (fun path -> files (Filename.concat root path))
    |> List.sort String.compare
    |> List.filter (fun path ->
         not (List.exists (fun allowed_path ->
           String.equal path (Filename.concat root allowed_path)) allowed))
    |> List.concat_map check_file
  in
  List.iter (fun (path, line) ->
    Printf.eprintf "%s:%d: construct maps and sets through Value.map/Value.set\n" path line)
    violations;
  if violations <> [] then exit 1;
  print_endline "Value constructors: all maps and sets use canonical smart constructors"
