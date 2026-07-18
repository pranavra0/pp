let stdlib_root () =
  try
    let exe_dir = Filename.dirname (Unix.realpath Sys.executable_name) in
    let candidate = Filename.concat (Filename.dirname exe_dir) "stdlib" in
    if Sys.file_exists candidate && Sys.is_directory candidate then Some candidate else None
  with _ -> None

let canonical_impl p =
  let abs = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p in
  let n = String.length abs in
  let abs = if n > 1 && abs.[n - 1] = '/' then String.sub abs 0 (n - 1) else abs in
  let parts = List.filter (fun s -> s <> "") (String.split_on_char '/' abs) in
  let rec split_existing n =
    if n = 0 then ("/", parts)
    else
      let candidate = "/" ^ String.concat "/" (List.filteri (fun i _ -> i < n) parts) in
      if Sys.file_exists candidate then
        (candidate, List.filteri (fun i _ -> i >= n) parts)
      else split_existing (n - 1)
  in
  let existing, remaining = split_existing (List.length parts) in
  let real_existing = try Unix.realpath existing with _ -> existing in
  let tail = List.rev (List.fold_left (fun acc -> function
    | "." -> acc | ".." -> (match acc with _ :: xs -> xs | [] -> [])
    | x -> x :: acc) [] remaining) in
  Nfc.nfc_normalize
    (match tail with [] -> real_existing | _ -> real_existing ^ "/" ^ String.concat "/" tail)

let canonical p = Paths.canonicalize ~realpath:canonical_impl p
