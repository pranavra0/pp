type request = {
  tool : Pp_kernel.Artifact_tree.t;
  tool_path : string;
  arguments : string list;
  inputs : Pp_kernel.Artifact_tree.t;
  environment : (string * string) list;
  platform : (string * string) list;
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

type t = request -> result

let sort_pairs pairs = List.sort (fun (a, _) (b, _) -> String.compare a b) pairs

let reject_duplicates label pairs =
  let rec check = function
    | (first, _) :: (second, _) :: _ when first = second ->
        failwith ("run-closed!: executor returned duplicate " ^ label ^ ": " ^ first)
    | _ :: rest -> check rest
    | [] -> ()
  in
  check pairs

let run (executor : t) (request : request) =
  let result : result = executor request in
  let evidence = sort_pairs result.evidence in
  let resources = sort_pairs result.resources in
  reject_duplicates "evidence name" evidence;
  reject_duplicates "resource name" resources;
  { result with evidence; resources }
