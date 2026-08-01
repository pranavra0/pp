open Pp_kernel
open Core_model

type shape = Any | Exact of int | Range of int * int option
type category =
  | Arithmetic | Collections | Strings | Capabilities | Observations
  | Process | Domains | Diagnostics | Metaprogramming | Other

type descriptor = {
  name : string;
  shape : shape;
  category : category;
  implementation : value list -> env -> value;
}

type t = {
  mutable declarations : descriptor list;
  mutable entries : descriptor list;
  mutable aliases : (string * string) list;
  builtins : (string, value) Hashtbl.t;
}

let create () = {
  declarations = [];
  entries = [];
  aliases = [];
  builtins = Hashtbl.create 64;
}

let register catalog ?(shape = Any) ?(category = Other) name implementation =
  catalog.declarations <- { name; shape; category; implementation }
    :: catalog.declarations

let alias catalog ~alias ~target =
  catalog.aliases <- (alias, target) :: catalog.aliases

let finalize catalog =
  catalog.entries <- List.rev catalog.declarations;
  List.iter (fun descriptor ->
    Hashtbl.replace catalog.builtins descriptor.name
      (VBuiltin (descriptor.name, descriptor.implementation))) catalog.entries;
  List.iter (fun (alias, target) ->
    match Hashtbl.find_opt catalog.builtins target with
    | Some value -> Hashtbl.replace catalog.builtins alias value
    | None -> failwith ("primitive alias target is not registered: " ^ target))
    catalog.aliases

let lookup catalog name = Hashtbl.find_opt catalog.builtins name

let initial_env catalog =
  Hashtbl.fold (fun name value bindings -> (name, value) :: bindings)
    catalog.builtins []
  |> Environment.of_bindings

let shape_string = function
  | Any -> "any"
  | Exact count -> string_of_int count
  | Range (minimum, None) -> Printf.sprintf "%d+" minimum
  | Range (minimum, Some maximum) -> Printf.sprintf "%d..%d" minimum maximum

let category_string = function
  | Arithmetic -> "arithmetic"
  | Collections -> "collections"
  | Strings -> "strings"
  | Capabilities -> "capabilities"
  | Observations -> "observations"
  | Process -> "process"
  | Domains -> "domains"
  | Diagnostics -> "diagnostics"
  | Metaprogramming -> "metaprogramming"
  | Other -> "other"

let render catalog =
  let row descriptor = Printf.sprintf "| `%s` | %s | %s |"
      descriptor.name (shape_string descriptor.shape)
      (category_string descriptor.category)
  in
  let public_entries =
    List.filter (fun descriptor -> not (String.contains descriptor.name '\000'))
      catalog.entries
  in
  String.concat "\n" ("| builtin | arity | category |" ::
    "|---|---|---|" :: List.map row public_entries) ^ "\n"
