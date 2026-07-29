open Core_model

type entry =
  | File of { path : string; mode : int; blob : string }
  | Directory of { path : string; mode : int }
  | Symlink of { path : string; target : string }

type t = entry list

let error format = Printf.ksprintf (fun message -> Error message) format

let is_hash value =
  String.length value = 64
  && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) value

let path_of_entry = function
  | File { path; _ } | Directory { path; _ } | Symlink { path; _ } -> path

let valid_path path =
  path <> ""
  && Filename.is_relative path
  && not (String.contains path '\000')
  && String.split_on_char '/' path
     |> List.for_all (fun part -> part <> "" && part <> "." && part <> "..")

let fields = function
  | VMap fields ->
      let names =
        List.map (function
          | VKeyword name, value -> Ok (name, value)
          | _ -> Error "tree entry fields must use keyword keys")
          fields
      in
      if List.exists Result.is_error names then
        List.find_map (function Error message -> Some (Error message) | Ok _ -> None) names
        |> Option.get
      else
        let fields = List.filter_map (function Ok field -> Some field | Error _ -> None) names in
        let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
        let rec duplicate = function
          | (a, _) :: (b, _) :: _ when a = b -> Some a
          | _ :: rest -> duplicate rest
          | [] -> None
        in
        (match duplicate sorted with
         | Some name -> error "duplicate tree entry field :%s" name
         | None -> Ok sorted)
  | _ -> Error "tree entries must be maps"

let exact expected fields =
  List.map fst fields = List.sort String.compare expected

let field name fields = List.assoc_opt name fields

let mode = function
  | VInt mode when mode >= 0 && mode <= 0o777 -> Ok mode
  | _ -> Error "tree entry mode must be an integer from 0 through 511"

let entry path value =
  if not (valid_path path) then error "non-canonical tree path: %s" path
  else
    match fields value with
    | Error _ as result -> result
    | Ok fields ->
        match field "kind" fields with
        | Some (VKeyword "file") when exact ["blob"; "kind"; "mode"] fields ->
            (match field "mode" fields, field "blob" fields with
             | Some mode_value, Some (VString blob) when is_hash blob ->
                 Result.map (fun mode -> File { path; mode; blob }) (mode mode_value)
             | _, Some (VString blob) -> error "invalid blob identity for tree path: %s (%s)" path blob
             | _ -> error "invalid file entry for tree path: %s" path)
        | Some (VKeyword "directory") when exact ["kind"; "mode"] fields ->
            (match field "mode" fields with
             | Some mode_value ->
                 Result.map (fun mode -> Directory { path; mode }) (mode mode_value)
             | None -> error "invalid directory entry for tree path: %s" path)
        | Some (VKeyword "symlink") when exact ["kind"; "target"] fields ->
            (match field "target" fields with
             | Some (VString target) when not (String.contains target '\000') ->
                 Ok (Symlink { path; target })
             | _ -> error "invalid symlink entry for tree path: %s" path)
        | Some (VKeyword kind) -> error "invalid tree entry kind or fields at %s: %s" path kind
        | _ -> error "tree entry is missing :kind at path: %s" path

let validate_parents entries =
  let table = Hashtbl.create (List.length entries) in
  List.iter (fun entry -> Hashtbl.add table (path_of_entry entry) entry) entries;
  let rec parents path =
    let parent = Filename.dirname path in
    if parent = "." then Ok ()
    else
      match Hashtbl.find_opt table parent with
      | Some (Directory _) -> parents parent
      | Some _ -> error "tree path has a non-directory parent: %s" path
      | None -> error "tree path has a missing parent directory: %s" path
  in
  List.fold_left (fun result entry ->
    Result.bind result (fun () -> parents (path_of_entry entry)))
    (Ok ()) entries

let rec duplicate = function
  | a :: b :: _ when String.equal a b -> Some a
  | _ :: rest -> duplicate rest
  | [] -> None

let of_value = function
  | VMap [VKeyword "tree", VMap entries] ->
      let parsed =
        List.map (function
          | VString path, value -> entry path value
          | _ -> Error "tree paths must be string keys")
          entries
      in
      (match List.find_map (function Error message -> Some message | Ok _ -> None) parsed with
       | Some message -> Error message
       | None ->
           let entries = List.filter_map (function Ok entry -> Some entry | Error _ -> None) parsed in
           let paths = List.map path_of_entry entries |> List.sort String.compare in
           (match duplicate paths with
            | Some path -> error "duplicate tree path: %s" path
            | None ->
                Result.map (fun () ->
                  List.sort (fun a b -> String.compare (path_of_entry a) (path_of_entry b)) entries)
                  (validate_parents entries)))
  | _ -> Error "tree must be exactly {:tree -> {path -> entry}}"

let descriptor = function
  | File { mode; blob; _ } ->
      Value.map [VKeyword "kind", VKeyword "file";
                 VKeyword "mode", VInt mode;
                 VKeyword "blob", VString blob]
  | Directory { mode; _ } ->
      Value.map [VKeyword "kind", VKeyword "directory";
                 VKeyword "mode", VInt mode]
  | Symlink { target; _ } ->
      Value.map [VKeyword "kind", VKeyword "symlink";
                 VKeyword "target", VString target]

let to_value entries =
  Value.map [VKeyword "tree",
    Value.map (List.map (fun entry -> VString (path_of_entry entry), descriptor entry) entries)]

let validate entries =
  let invalid_entry =
    List.find_map (fun candidate ->
      match entry (path_of_entry candidate) (descriptor candidate) with
      | Ok _ -> None
      | Error message -> Some message)
      entries
  in
  let result =
    match invalid_entry with
    | Some message -> Error message
    | None ->
        let paths = List.map path_of_entry entries |> List.sort String.compare in
        (match duplicate paths with
         | Some path -> error "duplicate tree path: %s" path
         | None -> validate_parents entries)
  in
  match result with
  | Ok () -> ()
  | Error message -> failwith ("invalid artifact tree: " ^ message)

let blob_hashes entries =
  List.filter_map (function File { blob; _ } -> Some blob | _ -> None) entries
  |> List.sort_uniq String.compare

let rec reachable_blobs value =
  match of_value value with
  | Ok tree -> blob_hashes tree
  | Error _ ->
      match value with
      | VPair (head, tail) -> reachable_blobs head @ reachable_blobs tail
      | VVector values -> Array.to_list values |> List.concat_map reachable_blobs
      | VMap entries ->
          List.concat_map (fun (key, value) ->
            reachable_blobs key @ reachable_blobs value) entries
      | VSet values -> List.concat_map reachable_blobs values
      | _ -> []
      |> List.sort_uniq String.compare
