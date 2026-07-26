type request = {
  tool : Pp_kernel.Artifact_tree.t;
  tool_path : string;
  arguments : string list;
  inputs : Pp_kernel.Artifact_tree.t;
  environment : (string * string) list;
  platform : (string * string) list;
  policy : Pp_kernel.Core_model.value;
  outputs : string list;
}

type result = {
  exit_status : int;
  stdout : string;
  stderr : string;
  outputs : Pp_kernel.Artifact_tree.t;
  evidence : (string * string) list;
  resources : (string * string) list;
}

type cacheability =
  | Cacheable
  | Scripting_only of string

type t = {
  classify : request -> cacheability;
  execute : request -> result;
}

let make ~classify ~execute = { classify; execute }
let cacheability executor request = executor.classify request

let sort_pairs pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs

let reject_duplicates label pairs =
  let rec check = function
    | (first, _) :: (second, _) :: _ when first = second ->
        failwith ("run-closed!: executor returned duplicate " ^ label ^ ": " ^ first)
    | _ :: rest -> check rest
    | [] -> ()
  in
  check pairs

let validate_metadata label pairs =
  List.iter (fun (name, value) ->
    if name = "" || String.contains name '\000' || String.contains value '\000' then
      failwith ("run-closed!: executor returned invalid " ^ label ^ ": " ^ name))
    pairs

let run (executor : t) (request : request) =
  let result : result = executor.execute request in
  let evidence = sort_pairs result.evidence in
  let resources = sort_pairs result.resources in
  reject_duplicates "evidence name" evidence;
  reject_duplicates "resource name" resources;
  validate_metadata "evidence" evidence;
  validate_metadata "resource" resources;
  Pp_kernel.Artifact_tree.validate result.outputs;
  { result with evidence; resources }
