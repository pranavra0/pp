open Pp_frontend
open Pp_kernel
open Core_model
open Pp_runtime
open Source_error

 type dependency = {
  name : string;
  uri : string;
  pin : string;
}

type t = {
  path : string;
  root : string;
  name : string;
  version : string;
  entry : string;
  test_roots : string list;
  dependencies : dependency list;
}

let fail path message = command (Printf.sprintf "project %s: %s" path message)

let read_file path =
  let ic = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in_noerr ic)
    (fun () -> really_input_string ic (in_channel_length ic))

let canonical path = (World_path.canonical path :> string)

let unwrap = function
  | ELocated (_, expr) -> expr
  | expr -> expr

let located_range = function
  | ELocated (range, _) -> Some range
  | _ -> None

let is_lower c = c >= 'a' && c <= 'z'
let is_digit c = c >= '0' && c <= '9'
let is_alnum c = is_lower c || (c >= 'A' && c <= 'Z') || is_digit c

let project_name_ok name =
  let n = String.length name in
  if n = 0 || not (is_lower name.[0]) then false
  else
    let rec segment start i =
      if i = n then i > start
      else if name.[i] = '-' then i > start && segment (i + 1) (i + 1)
      else if is_lower name.[i] || is_digit name.[i] then segment start (i + 1)
      else false
    in
    segment 0 0

let semver_identifier_ok identifier ~numeric =
  let n = String.length identifier in
  n > 0
  && String.for_all (fun c -> is_alnum c || c = '-') identifier
  && (not numeric || (String.for_all is_digit identifier
                      && (n = 1 || identifier.[0] <> '0')))

let semver_ok version =
  let core_and_build = String.split_on_char '+' version in
  match core_and_build with
  | [core] | [core; _] ->
      let core, prerelease =
        match String.split_on_char '-' core with
        | [core] -> core, []
        | [core; pre] -> core, String.split_on_char '.' pre
        | _ -> "", []
      in
      let core_parts = String.split_on_char '.' core in
      List.length core_parts = 3
      && List.for_all
           (fun part -> semver_identifier_ok part ~numeric:true) core_parts
      && List.for_all
           (fun part -> semver_identifier_ok part ~numeric:(String.for_all is_digit part))
           prerelease
      && (match core_and_build with
          | [_] -> true
          | [_; build] -> build <> ""
             && List.for_all (fun part -> semver_identifier_ok part ~numeric:false)
                   (String.split_on_char '.' build)
          | _ -> false)
  | _ -> false

let proper_list value =
  let rec loop acc = function
    | VNil -> Some (List.rev acc)
    | VPair (head, tail) -> loop (head :: acc) tail
    | _ -> None
  in
  loop [] value

let rec data_value path value =
  match value with
  | VNil | VBool _ | VInt _ | VString _ | VKeyword _ | VSymbol _ -> value
  | VFloat f when Float.is_finite f -> value
  | VPair (head, tail) ->
      VPair (data_value path head, data_value path tail)
  | VVector values ->
      VVector (Array.map (data_value path) values)
  | VMap entries ->
      let seen = Hashtbl.create (List.length entries) in
      let entries = List.map (fun (key, value) ->
        let key = data_value path key in
        let hash = Identity.hash_value key in
        if Hashtbl.mem seen hash then fail path "project map contains duplicate keys";
        Hashtbl.add seen hash ();
        key, data_value path value) entries in
      Value.map entries
  | VSet values -> Value.set (List.map (data_value path) values)
  | _ -> fail path "project manifest contains a non-data value"

let rec data_expr path expr =
  match unwrap expr with
  | ELiteral value -> data_value path value
  | EApply (fn, args) ->
      (match unwrap fn with
       | ESymbol "vector" -> VVector (Array.of_list (List.map (data_expr path) args))
       | ESymbol "list" ->
           List.fold_right (fun arg tail -> VPair (data_expr path arg, tail)) args VNil
       | ESymbol "hash-map" ->
           if List.length args mod 2 <> 0 then fail path "project map has an odd number of entries";
           let rec pairs acc = function
             | key :: value :: rest -> pairs ((data_expr path key, data_expr path value) :: acc) rest
             | [] -> List.rev acc
             | _ -> assert false
           in
           let entries = pairs [] args in
           let seen = Hashtbl.create (List.length entries) in
           List.iter (fun (key, _) ->
             let hash = Identity.hash_value key in
             if Hashtbl.mem seen hash then fail path "project map contains duplicate keys";
             Hashtbl.add seen hash ()) entries;
           Value.map entries
       | ESymbol "set" -> Value.set (List.map (data_expr path) args)
       | _ -> fail path "project manifest contains an executable expression")
  | _ -> fail path "project manifest contains an executable expression"

let field name fields =
  List.find_map (function
    | VKeyword key, value when key = name -> Some value
    | _ -> None) fields

let map_fields path = function
  | VMap fields -> fields
  | _ -> fail path ": project must be a map"

let string_field path name fields =
  match field name fields with
  | Some (VString value) -> value
  | Some _ -> fail path (":" ^ name ^ " must be a string")
  | None -> fail path ("project is missing :" ^ name)

let test_roots_field path fields =
  let value = match field "test-roots" fields with
    | Some value -> value
    | None -> fail path "project is missing :test-roots"
  in
  let values = match value with
    | VVector values -> Array.to_list values
    | _ -> Option.value ~default:[] (proper_list value)
  in
  if values = [] then fail path ":test-roots must be nonempty";
  List.map (function
    | VString value when value <> "" -> value
    | _ -> fail path ":test-roots must contain only nonempty strings") values

let path_is_file path =
  Sys.file_exists path &&
  (try (Unix.stat path).Unix.st_kind = Unix.S_REG with Unix.Unix_error _ -> false)

let path_is_dir path =
  Sys.file_exists path &&
  (try (Unix.stat path).Unix.st_kind = Unix.S_DIR with Unix.Unix_error _ -> false)

let contained root path =
  Paths.under ~root:(World_path.canonical root) (World_path.canonical path)
let validate_project_path path root kind value =
  if value = "" then fail path (":" ^ kind ^ " must be nonempty");
  let full = if Filename.is_relative value then Filename.concat root value else value in
  if not (kind = "entry" && (Filename.check_suffix value ".pp"
                             || Filename.check_suffix value ".ppl"))
     && kind = "entry" then
    fail path ":entry must name a .pp or .ppl file";
  if not (if kind = "entry" then path_is_file full else path_is_dir full) then
    fail path (":" ^ kind ^ " does not exist: " ^ value);
  let canonical_full = canonical full in
  if not (Paths.under ~root:(World_path.canonical root) (World_path.canonical full)) then
    fail path (":" ^ kind ^ " escapes the project directory: " ^ value);
  canonical_full
let valid_dependency_name name =
  let n = String.length name in
  n > 0 && is_lower name.[0]
  && String.for_all (fun c -> is_lower c || is_digit c || c = '-') name
  && name.[n - 1] <> '-'
  && not (List.mem name [
       "and"; "assert"; "def"; "defmacro"; "delay"; "do"; "else"; "export";
       "force"; "fn"; "if"; "import"; "island"; "let"; "let*"; "load";
       "load-module"; "mod"; "module"; "needs"; "node"; "or"; "perform";
       "quasiquote"; "quote"; "with-caps"; "with-config"; "with-handler" ])

let is_pin pin =
  String.length pin = 64
  && String.for_all (fun c ->
       (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) pin

let parse_dependency path name rhs =
  if not (valid_dependency_name name) then
    fail path ("invalid dependency name: " ^ name);
  match unwrap rhs with
  | EIsland (uri, Some pin) when is_pin pin -> { name; uri; pin }
  | EIsland (_, None) -> fail path ("dependency " ^ name ^ " has no content pin")
  | EIsland (_, Some _) -> fail path ("dependency " ^ name ^ " has an invalid content pin")
  | _ -> fail path ("dependency " ^ name ^ " must be an island declaration")

let decode_file path =
  let path = canonical path in
  if not (path_is_file path) then fail path "manifest does not exist";
  if not (Filename.check_suffix path ".pp") then fail path "manifest must be project.pp";
  let root = canonical (Filename.dirname path) in
  let source = read_file path in
  let forms = Reader_braces.read_dispatch ~source:path ~path source in
  let project_binding = ref None in
  let dependencies : dependency list ref = ref [] in
  let exports = ref [] in
  List.iter (fun form ->
    match unwrap form with
    | EDefValue (name, rhs) when name = "project" ->
        if Option.is_some !project_binding then fail path "duplicate project binding";
        project_binding := Some (form, rhs)
    | EDefValue (name, rhs) ->
        if List.exists (fun (dep : dependency) -> dep.name = name) !dependencies then
          fail path ("duplicate dependency binding: " ^ name);
        dependencies := parse_dependency path name rhs :: !dependencies
    | EExport names ->
        if !exports <> [] then fail path "manifest must contain exactly one export";
        exports := names
    | _ -> fail path "manifest may contain only direct let bindings and one export") forms;
  let project_rhs = match !project_binding with
    | Some (_, rhs) -> rhs
    | None -> fail path "manifest is missing direct let project binding"
  in
  let project_value = data_expr path project_rhs in
  let fields = map_fields path project_value in
  let allowed = ["name"; "version"; "entry"; "test-roots"] in
  List.iter (fun (key, _) -> match key with
    | VKeyword key when List.mem key allowed -> ()
    | VKeyword key -> fail path ("unknown project key: :" ^ key)
    | _ -> fail path "project map keys must be keywords") fields;
  let name = string_field path "name" fields in
  if not (project_name_ok name) then fail path ("invalid project name: " ^ name);
  let version = string_field path "version" fields in
  if not (semver_ok version) then fail path ("invalid SemVer version: " ^ version);
  let entry_value = string_field path "entry" fields in
  let entry = validate_project_path path root "entry" entry_value in
  let test_roots = test_roots_field path fields in
  let test_roots = List.map (validate_project_path path root "test-roots") test_roots in
  let dependencies = List.sort
      (fun (a : dependency) (b : dependency) -> String.compare a.name b.name)
      !dependencies in
  let expected_exports = "project" :: List.map (fun (dep : dependency) -> dep.name) dependencies in
  if !exports = [] then fail path "manifest is missing its export declaration";
  let exported = List.sort String.compare !exports in
  if List.sort String.compare expected_exports <> exported
     || List.length !exports <> List.length exported then
    fail path "export must contain project and exactly the dependency names";
  if List.exists (fun (dep : dependency) ->
      dep.name = "project" || dep.name = name) dependencies then
    fail path "dependency name collides with a project binding";
  { path; root; name; version; entry; test_roots; dependencies }

let nearest ?start () =
  let initial = match start with
    | Some path -> if path_is_dir path then path else Filename.dirname path
    | None -> Sys.getcwd ()
  in
  let rec loop dir =
    let candidate = Filename.concat dir "project.pp" in
    if path_is_file candidate then Some (canonical candidate)
    else
      let parent = Filename.dirname dir in
      if parent = dir then None else loop parent
  in
  loop (canonical initial)

let select explicit start =
  match explicit with
  | Some path ->
      let path = if path_is_dir path then Filename.concat path "project.pp" else path in
      let path = canonical path in
      if not (path_is_file path) then command ("project manifest not found: " ^ path);
      path
  | None ->
      (match nearest ~start () with
       | Some path -> path
       | None -> command "no project.pp found in this directory or an ancestor")

let resolve_uri ~root uri =
  if String.starts_with ~prefix:"file:" uri then
    let rest = String.sub uri 5 (String.length uri - 5) in
    let locator, suffix = match String.index_opt rest '#' with
      | Some index -> String.sub rest 0 index, String.sub rest index (String.length rest - index)
      | None -> rest, ""
    in
    if Filename.is_relative locator then
      "file:" ^ Filename.concat root locator ^ suffix
    else uri
  else uri

let located_start form = match located_range form with
  | Some range -> (Source_range.start range).Source_range.offset
  | None -> 0

let located_end form = match located_range form with
  | Some range -> (Source_range.end_ range).Source_range.offset
  | None -> 0


let atomic_write path content =
  let mode = (Unix.stat path).Unix.st_perm in
  let tmp = path ^ ".tmp." ^ string_of_int (Unix.getpid ()) in
  let oc = open_out_bin tmp in
  let committed = ref false in
  Fun.protect
    ~finally:(fun () -> close_out_noerr oc; if not !committed then (try Sys.remove tmp with _ -> ()))
    (fun () ->
      output_string oc content;
      close_out oc;
      Unix.chmod tmp mode;
      Unix.rename tmp path;
      committed := true)

let apply_splices source splices =
  let splices = List.sort (fun (a, _, _) (b, _, _) -> compare b a) splices in
  List.fold_left (fun text (start, length, replacement) ->
    String.sub text 0 start ^ replacement
    ^ String.sub text (start + length) (String.length text - start - length))
    source splices

let export_form forms =
  List.find_map (fun form -> match unwrap form with EExport _ -> Some form | _ -> None) forms

let rewrite manifest make_splices =
  let source = read_file manifest.path in
  let forms = Reader_braces.read_dispatch ~source:manifest.path ~path:manifest.path source in
  let splices = make_splices forms in
  atomic_write manifest.path (apply_splices source splices)

let export_names manifest =
  "project" :: List.map (fun (dep : dependency) -> dep.name) manifest.dependencies

let add_dependency manifest ~name ~uri =
  if not (valid_dependency_name name) then fail manifest.path ("invalid dependency name: " ^ name);
  if name = "project" || name = manifest.name then
    fail manifest.path ("dependency name collides with a project binding: " ^ name);
  if List.exists (fun (dep : dependency) -> dep.name = name) manifest.dependencies then
    fail manifest.path ("dependency already exists: " ^ name);
  let pin = Island.repin (resolve_uri ~root:manifest.root uri) in
  let rhs = EDefValue (name, EIsland (uri, Some pin)) in
  rewrite manifest (fun forms ->
    let project_form = List.find_map (fun form -> match unwrap form with
      | EDefValue ("project", _) -> Some form | _ -> None) forms in
    let existing = List.filter_map (fun form -> match unwrap form with
      | EDefValue (dep, _) when dep <> "project" -> Some (dep, form)
      | _ -> None) forms in
    let next = List.find_opt (fun (dep, _) -> String.compare name dep < 0) existing in
    let insertion = match next with
      | Some (_, form) -> located_start form
      | None ->
          (match export_form forms with
           | Some form -> located_start form
           | None -> String.length (read_file manifest.path))
    in
    let text = Printer_braces.print_expr_string rhs in
    let text = if insertion > 0 then text ^ "\n" else text in
    let _ = project_form in
    [insertion, 0, text;
     (match export_form forms with
      | Some form ->
          let names = List.sort String.compare (export_names manifest @ [name]) in
          let names = "project" :: List.filter ((<>) "project") names in
          located_start form, located_end form - located_start form,
          Printer_braces.print_expr_string (EExport names)
      | None -> fail manifest.path "manifest is missing its export declaration")])

let remove_dependency manifest ~name =
  let dep = match List.find_opt (fun (dep : dependency) -> dep.name = name)
      manifest.dependencies with
    | Some dep -> dep
    | None -> fail manifest.path ("dependency not found: " ^ name)
  in
  let _ = dep in
  rewrite manifest (fun forms ->
    let binding = List.find_map (fun form -> match unwrap form with
      | EDefValue (dep_name, _) when dep_name = name -> Some form
      | _ -> None) forms in
    let binding = match binding with
      | Some form -> form
      | None -> fail manifest.path ("dependency binding not found: " ^ name)
    in
    let export = match export_form forms with
      | Some form -> form
      | None -> fail manifest.path "manifest is missing its export declaration"
    in
    let names = List.filter ((<>) name) (export_names manifest) in
    [located_start binding, located_end binding - located_start binding, "";
     located_start export, located_end export - located_start export,
     Printer_braces.print_expr_string (EExport names)])

let update_dependencies manifest selected =
  let dependencies = match selected with
    | Some name ->
        (match List.find_opt (fun (dep : dependency) -> dep.name = name)
             manifest.dependencies with
         | Some dep -> [dep]
         | None -> fail manifest.path ("dependency not found: " ^ name))
    | None -> manifest.dependencies
  in
  let repins = List.map (fun (dep : dependency) ->
    dep, Island.repin (resolve_uri ~root:manifest.root dep.uri)) dependencies in
  rewrite manifest (fun forms ->
    let splices = List.map (fun ((dep : dependency), pin) ->
      let form = List.find_map (fun form -> match unwrap form with
        | EDefValue (name, _) when name = dep.name -> Some form
        | _ -> None) forms in
      let form = match form with
        | Some form -> form
        | None -> fail manifest.path ("dependency binding not found: " ^ dep.name)
      in
      let start = located_start form and finish = located_end form in
      let old = String.sub (read_file manifest.path) start (finish - start) in
      let positions =
        let rec find from acc =
          match String.index_from_opt old from '"' with
          | None -> List.rev acc
          | Some left ->
              (match String.index_from_opt old (left + 1) '"' with
               | None -> List.rev acc
               | Some right ->
                   let value = String.sub old (left + 1) (right - left - 1) in
                   let acc = if value = dep.pin then (left + 1, right - left - 1) :: acc else acc in
                   find (right + 1) acc)
        in
        find 0 []
      in
      match positions with
      | [] -> fail manifest.path ("pin for dependency " ^ dep.name ^ " was not found")
      | _ ->
          let replacement = List.fold_left (fun text (at, length) ->
            String.sub text 0 at ^ pin
            ^ String.sub text (at + length) (String.length text - at - length))
            old (List.sort (fun (a, _) (b, _) -> compare b a) positions)
          in
          start, finish - start, replacement) repins in
    splices)
