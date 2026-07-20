let counter = ref 0

let remove_tree = Fswalk.remove_tree

let current ~create =
  match Effect.perform Dynamic_scope.Current_sandbox with
  | None -> None
  | Some slot -> (match !slot with
      | Some d -> Some d
      | None when create ->
          incr counter;
          let d = Filename.concat (Filename.get_temp_dir_name ())
              (Printf.sprintf "pp-sandbox-%d-%d" (Unix.getpid ()) !counter) in
          (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
          slot := Some d; Some d
      | None -> None)

let resolve ?(create = false) path =
  if Filename.is_relative path then
    match Effect.perform Dynamic_scope.Current_sandbox with
    | Some slot when Option.is_some !slot || create ->
        Option.map (fun d -> Filename.concat d path) (current ~create)
    | _ -> None
  else None
