exception Error of string

let error fmt = Printf.ksprintf (fun message -> raise (Error message)) fmt

let string_lit s =
  let buffer = Buffer.create (String.length s + 2) in
  Buffer.add_char buffer '"';
  String.iter (function
    | '\\' -> Buffer.add_string buffer "\\\\"
    | '"' -> Buffer.add_string buffer "\\\""
    | '\n' -> Buffer.add_string buffer "\\n"
    | '\t' -> Buffer.add_string buffer "\\t"
    | c -> Buffer.add_char buffer c) s;
  Buffer.add_char buffer '"';
  Buffer.contents buffer

let float_lit f =
  if f <> f || f = infinity || f = neg_infinity then
    error "float %h has no surface literal" f;
  let ensure_dot s =
    if String.contains s '.' then s
    else match String.index_opt s 'e' with
      | Some i -> String.sub s 0 i ^ "." ^ String.sub s i (String.length s - i)
      | None -> s ^ "."
  in
  let bits = Int64.bits_of_float f in
  let round_trips s =
    match float_of_string_opt s with
    | Some g when Int64.bits_of_float g = bits -> Some s
    | _ -> None
  in
  match round_trips (ensure_dot (string_of_float f)) with
  | Some s -> s
  | None ->
      (match round_trips (ensure_dot (Printf.sprintf "%.17g" f)) with
       | Some s -> s
       | None -> error "float %h does not round-trip through its literal" f)

open Pp_kernel.Core_model

type inverted = {
  i_loc : (string * int) option;
  i_annots : (string * expr) list;
  i_ret : expr option;
  i_body : expr;
}

let invert_fn_body params body =
  let fail fmt = Printf.ksprintf Result.error fmt in
  let tail_part = function
    | ELocated (loc, ETyped (body, ty)) -> Ok (loc, Some ty, body)
    | ELocated (loc, body) -> Ok (loc, None, body)
    | _ -> Result.Error "function body is not in assemble_fn_body shape"
  in
  let decode_checks checks last =
    if checks = [] then Result.Error "function body EDo without parameter checks"
    else
      let rec collect acc = function
        | [] -> Ok (List.rev acc)
        | ELocated (loc, ETyped (ESymbol param, ty)) :: rest ->
            collect ((loc, param, ty) :: acc) rest
        | _ -> Result.Error "function body is not in assemble_fn_body shape"
      in
      match collect [] checks, tail_part last with
      | Result.Error message, _ | _, Result.Error message -> Result.Error message
      | Ok located_annots, Ok (loc, i_ret, i_body) ->
          if List.exists (fun (check_loc, _, _) -> check_loc <> loc) located_annots then
            Result.Error "parameter checks carry inconsistent locations"
          else
            let i_annots =
              List.map (fun (_, param, ty) -> (param, ty)) located_annots in
            let rec valid remaining_params remaining_annots =
              match remaining_params, remaining_annots with
              | _, [] -> true
              | param :: params, (annotated, _) :: annots when param = annotated ->
                  valid params annots
              | _ :: params, annots -> valid params annots
              | [], _ :: _ -> false
            in
            if valid params i_annots then
              Ok { i_loc = Some loc; i_annots; i_ret; i_body }
            else fail "parameter checks do not match the parameter list"
  in
  match body with
  | EDo items when items <> [] ->
      (match List.rev items with
       | last :: reversed_checks -> decode_checks (List.rev reversed_checks) last
       | [] -> Ok { i_loc = None; i_annots = []; i_ret = None; i_body = body })
  | ELocated _ ->
      Result.map (fun (loc, i_ret, i_body) ->
        { i_loc = Some loc; i_annots = []; i_ret; i_body }) (tail_part body)
  | i_body -> Ok { i_loc = None; i_annots = []; i_ret = None; i_body }

let block_stmts_of = function
  | EDo statements when List.length statements >= 2 -> statements
  | expression -> [expression]

let leading_anchor = function
  | ELocated ((_, line), _) -> Some line
  | EDefValue (_, ELocated ((_, line), _)) -> Some line
  | EFn (params, body) | EDef (_, params, body) | EDefNode (_, params, body) ->
      (match invert_fn_body params body with
       | Ok { i_loc = Some (_, line); _ } -> Some line
       | Ok { i_loc = None; _ } | Result.Error _ -> None)
  | _ -> None
