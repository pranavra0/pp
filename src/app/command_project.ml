open Pp_kernel
open Pp_frontend
open Pp_runtime
open Source_error

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let write_file path content =
  let oc = open_out_gen [Open_wronly; Open_creat; Open_excl; Open_binary] 0o644 path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc)
    (fun () -> output_string oc content; close_out oc)

let command_args cli = Cli.files cli

let one_arg action args = match args with
  | [arg] -> arg
  | [] -> command ("pp " ^ action ^ ": expected one argument")
  | _ -> command ("pp " ^ action ^ ": expected one argument")

let zero_or_one_arg action args = match args with
  | [] -> None
  | [arg] -> Some arg
  | _ -> command ("pp " ^ action ^ ": expected zero or one argument")

let project_path cli start =
  Project_manifest.select (Cli.project_file cli) start

let is_lower c = c >= 'a' && c <= 'z'
let is_digit c = c >= '0' && c <= '9'

let valid_project_name name =
  let n = String.length name in
  if n = 0 || not (is_lower name.[0]) then false
  else
    let rec loop i previous_hyphen =
      if i = n then not previous_hyphen
      else
        let c = name.[i] in
        if c = '-' then i > 0 && not previous_hyphen && loop (i + 1) true
        else if is_lower c || is_digit c then loop (i + 1) false
        else false
    in
    loop 1 false

let mkdir path =
  try Unix.mkdir path 0o755 with
  | Unix.Unix_error (Unix.EEXIST, _, _) -> ()

let init cli =
  let requested = zero_or_one_arg "init" (command_args cli) in
  let target = match requested with
    | Some path -> path
    | None -> Sys.getcwd ()
  in
  let target =
    if Filename.is_relative target then Filename.concat (Sys.getcwd ()) target else target
  in
  let target_exists = Sys.file_exists target in
  if target_exists && not (Sys.is_directory target) then
    command ("pp init: target is not a directory: " ^ target);
  if target_exists && Sys.readdir target <> [||] then
    command ("pp init: target directory is not empty: " ^ target);
  let name = Filename.basename (String.trim target) in
  if not (valid_project_name name) then
    command ("pp init: directory basename is not a valid project name: " ^ name);
  let parent = Filename.dirname target in
  if not (Sys.file_exists parent && Sys.is_directory parent) then
    command ("pp init: parent directory does not exist: " ^ parent);
  let stage = Filename.concat parent
      (".pp-init-" ^ string_of_int (Unix.getpid ()) ^ "-" ^ string_of_int (Random.bits ())) in
  let installed = ref false in
  Fun.protect
    ~finally:(fun () -> if not !installed then Fswalk.remove_tree stage)
    (fun () ->
      mkdir stage;
      mkdir (Filename.concat stage "tests");
      write_file (Filename.concat stage "project.pp")
        (Printf.sprintf
           "export project\n\nlet project = {\n  :name -> \"%s\",\n  :version -> \"0.1.0\",\n  :entry -> \"build.pp\",\n  :test-roots -> [\"tests\"]\n}\n"
           name);
      write_file (Filename.concat stage "build.pp") "nil\n";
      write_file (Filename.concat stage "tests/project_test.pp")
        "import \"std:test\"\nexpect-true(true)\n";
      ignore (Project_manifest.decode_file (Filename.concat stage "project.pp"));
      if target_exists then begin
        Array.iter (fun child ->
          let source = Filename.concat stage child in
          let destination = Filename.concat target child in
          if Sys.file_exists destination then
            command ("pp init: refusing to overwrite " ^ destination);
          Unix.rename source destination)
          (Sys.readdir stage);
        Unix.rmdir stage
      end else
        Unix.rename stage target;
      installed := true;
      Printf.printf "initialized %s\n%!" target)

let with_fetch f =
  let old = !(Island.fetch_enabled) in
  Island.fetch_enabled := true;
  Fun.protect ~finally:(fun () -> Island.fetch_enabled := old) f

let add cli =
  let args = command_args cli in
  let name, uri = match args with
    | [name; uri] -> name, uri
    | _ -> command "pp add: expected NAME URI"
  in
  let manifest = Project_manifest.decode_file (project_path cli (Sys.getcwd ())) in
  with_fetch (fun () -> Project_manifest.add_dependency manifest ~name ~uri);
  let updated = Project_manifest.decode_file manifest.path in
  let dep = List.find
      (fun (dep : Project_manifest.dependency) -> dep.name = name)
      updated.dependencies in
  Printf.printf "added %s %s\n%!" name dep.pin

let update cli =
  let selected = zero_or_one_arg "update" (command_args cli) in
  let manifest = Project_manifest.decode_file (project_path cli (Sys.getcwd ())) in
  with_fetch (fun () -> Project_manifest.update_dependencies manifest selected);
  ignore (Project_manifest.decode_file manifest.path);
  Printf.printf "updated %s\n%!"
    (match selected with Some name -> name | None -> "all")

let remove cli =
  let name = one_arg "remove" (command_args cli) in
  let manifest = Project_manifest.decode_file (project_path cli (Sys.getcwd ())) in
  Project_manifest.remove_dependency manifest ~name;
  ignore (Project_manifest.decode_file manifest.path);
  Printf.printf "removed %s\n%!" name

let read_source path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))
let form_operations = {
  Evaluator_forms.eval = Evaluator.eval;
  eval_tail = (fun expr env next -> next (Evaluator.eval expr env));
  force = Evaluator.force;
}


let load_project_module services manifest (dep : Project_manifest.dependency) =
  let uri = Project_manifest.resolve_uri ~root:manifest.Project_manifest.root dep.uri in
  let tree = Island.resolve ~uri ~pin:(Some dep.pin) in
  let path = Island.entry_file tree in
  let source = read_source path in
  let expanded, macro_names =
    Macro.expand_module_file ~install_exports:true services ~path source
  in
  Evaluator_forms.module_expr ~macro_names form_operations expanded

let project_environment services manifest =
  let base = Primitives.initial_env () in
  List.fold_left (fun env (dep : Project_manifest.dependency) ->
    let value = load_project_module services manifest dep in
    Environment.extend env dep.name value)
    base manifest.dependencies

let execute_project_source ctx manifest source path =
  let session = App_context.session ctx in
  Repl.init session;
  let services = Repl.macro_services () in
  Repl.global_env := project_environment services manifest;
  let forms = Reader_braces.read_dispatch ~source:path ~path source in
  let expanded = List.concat_map (fun form ->
    Macro.expand_toplevel_list services [form]) forms in
  ignore (Evaluator.eval_expressions_list expanded Repl.global_env)

let build ctx cli =
  let manifest = Project_manifest.decode_file (project_path cli (Sys.getcwd ())) in
  let source = read_source manifest.entry in
  Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () -> execute_project_source ctx manifest source manifest.entry) ()

let execute_project cli ctx manifest =
  match Cli.eval_string cli, command_args cli with
  | Some source, [] ->
      Dynamic_scope.with_top_level (App_context.session ctx) (App_context.invocation ctx)
        ~f:(fun () -> execute_project_source ctx manifest source "<?>") ()
  | Some _, _ -> command "project execution does not accept source files with -e"
  | None, files ->
      if files = [] then command "project execution requires a source file or -e";
      List.iter (fun path ->
        let path = (World_path.canonical path :> string) in
        if not (Sys.file_exists path) then command ("project source does not exist: " ^ path);
        execute_project_source ctx manifest (read_source path) path) files

let has_test_suffix path = Filename.check_suffix path "_test.pp"
  || Filename.check_suffix path "_test.ppl"

let relative_to root path =
  let prefix = if root = "/" then "/" else root ^ "/" in
  if path = root then "."
  else if String.starts_with ~prefix path then
    String.sub path (String.length prefix) (String.length path - String.length prefix)
  else path

let discover roots project_root =
  let seen = Hashtbl.create 64 in
  let results = ref [] in
  let rec walk path =
    let canonical_path = (World_path.canonical path :> string) in
    if not (Paths.under ~root:(World_path.canonical project_root) (World_path.canonical canonical_path)) then
      command ("project test path escapes the project: " ^ path);
    if Hashtbl.mem seen canonical_path then ()
    else begin
      Hashtbl.add seen canonical_path ();
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR } ->
          Array.to_list (Sys.readdir path)
          |> List.sort String.compare
          |> List.iter (fun child -> walk (Filename.concat path child))
      | { Unix.st_kind = Unix.S_REG } when has_test_suffix path ->
          results := canonical_path :: !results
      | _ -> ()
    end
  in
  List.iter walk roots;
  List.sort_uniq String.compare !results

let open_output path = Unix.openfile path [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC] 0o600

let replace_env name value =
  let prefix = name ^ "=" in
  let kept = Array.to_list (Unix.environment ())
    |> List.filter (fun entry -> not (String.starts_with ~prefix entry)) in
  Array.of_list ((prefix ^ value) :: kept)

let print_child_output label path =
  if Sys.file_exists path then begin
    let text = read_file path in
    if text <> "" then begin
      Printf.printf "  %s:\n" label;
      String.split_on_char '\n' text
      |> List.iter (fun line -> if line <> "" then Printf.printf "    %s\n" line)
    end
  end

let run_child cli manifest index path temp_root =
  let stdout_path = Filename.concat temp_root (Printf.sprintf "%03d.out" index) in
  let stderr_path = Filename.concat temp_root (Printf.sprintf "%03d.err" index) in
  let store_root = Filename.concat temp_root (Printf.sprintf "store-%03d" index) in
  let args = ["--project"; manifest.Project_manifest.path]
    @ List.concat_map (fun grant -> ["--grant"; grant]) (Cli.grants cli)
    @ [path]
    @ (if Cli.program_argv cli = [] then [] else "--" :: Cli.program_argv cli)
  in
  let out_fd = open_output stdout_path in
  let err_fd = open_output stderr_path in
  let pid = Unix.create_process_env Sys.executable_name
      (Array.of_list (Sys.executable_name :: args))
      (replace_env "PP_STORE_ROOT" store_root)
      Unix.stdin out_fd err_fd in
  Unix.close out_fd;
  Unix.close err_fd;
  let _, status = Unix.waitpid [] pid in
  let code = match status with
    | Unix.WEXITED n -> n
    | Unix.WSIGNALED signal -> 128 + signal
    | Unix.WSTOPPED signal -> 128 + signal
  in
  (code, stdout_path, stderr_path)

let test ctx cli =
  let start = match command_args cli with
    | path :: _ -> path
    | [] -> Sys.getcwd ()
  in
  let manifest = Project_manifest.decode_file (project_path cli start) in
  let roots = match command_args cli with
    | [] -> manifest.test_roots
    | paths ->
        List.map (fun path ->
          let path = if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path in
          if not (Sys.file_exists path) then command ("project test path does not exist: " ^ path);
          let canonical_path = (World_path.canonical path :> string) in
          if not (Paths.under ~root:(World_path.canonical manifest.root)
                    (World_path.canonical canonical_path)) then
            command ("project test path escapes the project: " ^ path);
          canonical_path) paths
  in
  let tests = discover roots manifest.root in
  if tests = [] then command "project test: no *_test.pp or *_test.ppl files found";
  let temp_root = Filename.temp_file "pp-project-test-" "" in
  Sys.remove temp_root;
  Unix.mkdir temp_root 0o700;
  Fun.protect
    ~finally:(fun () -> Fswalk.remove_tree temp_root)
    (fun () ->
      let passed = ref 0 and failed = ref 0 in
      List.iteri (fun index path ->
        let code, stdout_path, stderr_path = run_child cli manifest index path temp_root in
        let relative = relative_to manifest.root path in
        if code = 0 then begin
          incr passed;
          Printf.printf "PASS %s\n%!" relative;
          if Cli.project_verbose cli then begin
            print_child_output "stdout" stdout_path;
            print_child_output "stderr" stderr_path
          end
        end else begin
          incr failed;
          Printf.printf "FAIL %s\n%!" relative;
          Printf.printf "  exit %d\n%!" code;
          print_child_output "stdout" stdout_path;
          print_child_output "stderr" stderr_path
        end)
        tests;
      Printf.printf "%d passed, %d failed, %d total\n%!" !passed !failed (List.length tests);
      if !failed <> 0 then exit 1)

let run_early _host cli =
  match Cli.project_command cli with
  | Some Cli.Project_init -> init cli; true
  | Some Cli.Project_add -> add cli; true
  | Some Cli.Project_update -> update cli; true
  | Some Cli.Project_remove -> remove cli; true
  | Some (Cli.Project_build | Cli.Project_test) | None -> false

let run ctx cli =
  match Cli.project_command cli with
  | Some Cli.Project_build -> build ctx cli; true
  | Some Cli.Project_test -> test ctx cli; true
  | Some (Cli.Project_init | Cli.Project_add | Cli.Project_update | Cli.Project_remove) -> false
  | None ->
      (match Cli.project_file cli with
       | Some project ->
           let manifest = Project_manifest.decode_file (Project_manifest.select (Some project) (Sys.getcwd ())) in
           execute_project cli ctx manifest;
           true
       | None -> false)
