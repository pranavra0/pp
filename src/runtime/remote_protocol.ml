open Pp_kernel
open Codec

type pin =
  | File_pin of { cell : string; hash : string }
  | Probe_pin of { name : string; value : Core_model.value }

type reply =
  | Hit of { key : string; result_hash : string; blob_hashes : string list }
  | Miss of string
  | Deny of string * string

let encode_file_pin ~cell ~hash =
  Printf.sprintf "(pin %s %s)\n" (quote_string cell) (quote_string hash)

let encode_probe_pin ~name value =
  match encode_value value with
  | Some encoded -> Ok (Printf.sprintf "(pin-probe %s %s)\n" (quote_string name) encoded)
  | None -> Error ("probe pin is not serializable: " ^ name)

let decode_file_pin line =
  expect_lit line 0 "(pin " >>= fun i ->
  parse_quoted_string line i >>= fun (cell, i) ->
  expect_char line i ' ' >>= fun i ->
  parse_quoted_string line i >>= fun (hash, i) ->
  expect_char line i ')' >>= fun i ->
  if i = String.length line then Some (File_pin { cell; hash }) else None

let decode_probe_pin line =
  expect_lit line 0 "(pin-probe " >>= fun i ->
  parse_quoted_string line i >>= fun (name, i) ->
  expect_char line i ' ' >>= fun i ->
  let length = String.length line in
  if i >= length || line.[length - 1] <> ')' then None
  else
    let encoded = String.sub line i (length - i - 1) in
    Option.map (fun value -> Probe_pin { name; value }) (decode_value encoded)

let decode_pin line =
  let line = String.trim line in
  match decode_file_pin line with
  | Some pin -> Ok pin
  | None ->
      (match decode_probe_pin line with
       | Some pin -> Ok pin
       | None -> Error ("unrecognized pin message: " ^ line))

let encode_reply = function
  | Deny (key, reason) -> Printf.sprintf "(serve-hit-reply deny %s %s)\n"
      (quote_string key) (quote_string reason)
  | Miss key -> Printf.sprintf "(serve-hit-reply miss %s)\n" (quote_string key)
  | Hit { key; result_hash; blob_hashes } ->
      Printf.sprintf "(serve-hit-reply hit %s %s (%s))\n"
        (quote_string key) (quote_string result_hash)
        (String.concat " " (List.map quote_string blob_hashes))

let decode_reply text =
  let text = String.trim text in
  let length = String.length text in
  let parsed =
    expect_lit text 0 "(serve-hit-reply " >>= fun i ->
    String.index_from_opt text i ' ' >>= fun separator ->
    let kind = String.sub text i (separator - i) in
    parse_quoted_string text (separator + 1) >>= fun (key, i) ->
    match kind with
    | "miss" -> expect_char text i ')' >>= fun _ -> Some (Miss key)
    | "deny" ->
        expect_char text i ' ' >>= fun i ->
        parse_quoted_string text i >>= fun (reason, i) ->
        expect_char text i ')' >>= fun _ -> Some (Deny (key, reason))
    | "hit" ->
        expect_char text i ' ' >>= fun i ->
        parse_quoted_string text i >>= fun (result_hash, i) ->
        expect_char text i ' ' >>= fun i ->
        expect_char text i '(' >>= fun i ->
        let rec hashes i acc =
          if i < length && text.[i] = ')' then Some (List.rev acc, i + 1)
          else
            parse_quoted_string text i >>= fun (hash, i) ->
            let i = if i < length && text.[i] = ' ' then i + 1 else i in
            hashes i (hash :: acc)
        in
        hashes i [] >>= fun (blob_hashes, i) ->
        expect_char text i ')' >>= fun _ ->
        Some (Hit { key; result_hash; blob_hashes })
    | _ -> None
  in
  match parsed with
  | Some reply -> Ok reply
  | None -> Error ("unrecognized serve-hit reply: " ^ text)
