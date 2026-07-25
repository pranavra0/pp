type request = {
  tool : string;
  arguments : string list;
  inputs : (string * string) list;
  environment : (string * string) list;
  platform : (string * string) list;
  outputs : string list;
}

type result = {
  exit_status : int;
  stdout : string;
  stderr : string;
  outputs : (string * string) list;
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
  let outputs = sort_pairs result.outputs in
  let evidence = sort_pairs result.evidence in
  let resources = sort_pairs result.resources in
  reject_duplicates "output path" outputs;
  reject_duplicates "evidence name" evidence;
  reject_duplicates "resource name" resources;
  let selected = List.sort String.compare request.outputs in
  if List.map fst outputs <> selected then
    failwith "run-closed!: executor outputs do not match the requested selection";
  { result with outputs; evidence; resources }
