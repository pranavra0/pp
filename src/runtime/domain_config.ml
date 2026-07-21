open Pp_kernel
open Core_model

type registration = {
  name : string;
  entry : Session.domain_entry;
}

let error fmt = Printf.ksprintf Result.error fmt

let string_like where value =
  match Presentation.string_like value with
  | Some text -> Ok text
  | None -> error "%s: expected a string or keyword, got %s"
      where (Presentation.string_of_value value)

let function_value where = function
  | (VClosure _ | VBuiltin _) as value -> Ok value
  | _ -> error "%s must be a function" where

let decode_domain ~force spec =
  let ( let* ) = Result.bind in
  let* fields =
    match force spec with
    | VMap fields -> Ok fields
    | value -> error "register-domain expects a map, got %s"
        (Presentation.string_of_value value)
  in
  let find key = Option.map (fun value -> force value)
      (Force_deep.find_kv ~force fields key) in
  let* name =
    match find "name" with
    | Some value -> string_like "register-domain :name" value
    | None -> Error "register-domain: missing :name"
  in
  let* namespace =
    match find "namespace" with
    | None | Some VNil -> Ok []
    | Some (VVector values) ->
        Array.fold_left (fun result value ->
          let* names = result in
          let* name = string_like "register-domain :namespace" (force value) in
          Ok (name :: names)) (Ok []) values
        |> Result.map List.rev
    | Some value -> error
        "register-domain :namespace must be a vector of strings, got %s"
        (Presentation.string_of_value value)
  in
  let* observe =
    match find "observe" with
    | Some value -> function_value "register-domain: :observe" value
    | None -> Error "register-domain: missing :observe"
  in
  let* write_cap =
    match find "write-cap" with
    | Some (VCapability capability) -> Ok capability
    | Some value -> error
        "register-domain :write-cap must be a capability, got %s"
        (Presentation.string_of_value value)
    | None -> Error "register-domain: missing :write-cap"
  in
  Ok {
    name;
    entry = {
      Session.dm_namespace = namespace;
      dm_observe = observe;
      dm_diff = find "diff";
      dm_apply = find "apply";
      dm_cap = write_cap;
      dm_observe_cell = find "observe-cell";
    };
  }

let decode_probe ~force name_value observe_value cap_value =
  let ( let* ) = Result.bind in
  let* name = string_like "register-probe name" (force name_value) in
  let* observe = function_value "register-probe: observe-fn" (force observe_value) in
  let* capability =
    match force cap_value with
    | VCapability capability -> Ok capability
    | _ -> Error "register-probe expects a name, an observe-fn, and a read capability"
  in
  Ok {
    name;
    entry = {
      Session.dm_namespace = [];
      dm_observe = observe;
      dm_diff = None;
      dm_apply = None;
      dm_cap = capability;
      dm_observe_cell = None;
    };
  }
