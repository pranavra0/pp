open Pp_kernel
open Core_model

type root = {
  gr_hash : string;
  gr_nodes : Identity_types.Node_key.t list;
}

let roots_path () =
  Filename.concat (Store_layout.root (Runtime_context.layout ())) "gc-roots"

let root_to_value root =
  VMap [
    VKeyword "hash", VString root.gr_hash;
    VKeyword "nodes",
      VVector (Array.of_list (List.map
        (fun key -> VString (Identity_types.Node_key.to_string key))
        root.gr_nodes));
  ]

let value_to_root = function
  | VMap fields ->
      (match List.assoc_opt (VKeyword "hash") fields,
             List.assoc_opt (VKeyword "nodes") fields with
       | Some (VString gr_hash), Some (VVector nodes) ->
           let rec decode acc = function
             | [] -> Some (List.rev acc)
             | VString key :: rest ->
                 decode (Identity_types.Node_key.of_string key :: acc) rest
             | _ -> None
           in
           Option.map (fun gr_nodes -> { gr_hash; gr_nodes })
             (decode [] (Array.to_list nodes))
       | _ -> None)
  | _ -> None

let read_all () =
  let path = roots_path () in
  if not (Sys.file_exists path) then []
  else
    String.split_on_char '\n' (Cell_repository.read_raw path)
    |> List.filter_map (fun line ->
         if line = "" then None
         else Option.bind (Codec.decode_value line) value_to_root)

let record ~keep root =
  Store_layout.ensure_dir (Store_layout.root (Runtime_context.layout ()));
  let existing = read_all () in
  let updated = existing @ [root] in
  let count = List.length updated in
  let kept =
    if keep > 0 && count > keep then
      List.filteri (fun index _ -> index >= count - keep) updated
    else updated
  in
  let lines = List.filter_map
      (fun item -> Codec.encode_value (root_to_value item)) kept in
  Store_layout.atomic_replace (roots_path ())
    (String.concat "\n" lines ^ if lines = [] then "" else "\n")
