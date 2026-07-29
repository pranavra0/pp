open Core_model

let canonicalize hash values =
  let unique = Hashtbl.create (List.length values) in
  List.iter (fun value -> Hashtbl.replace unique (hash value) value) values;
  Hashtbl.to_seq unique
  |> List.of_seq
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)
  |> List.map snd

let map entries =
  VMap (canonicalize (fun (key, _) -> Identity.hash_value key) entries)

let set values =
  VSet (canonicalize Identity.hash_value values)
