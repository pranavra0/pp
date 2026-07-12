(* pp store codec — one canonical, versioned, byte-stable TEXT encoding for
   DATA values (M2.2 / ROADMAP §3: the store must be readable across
   OS/arch/compiler, which OCaml Marshal is not).

   THE NON-DATA LAW: [encode_value] returns [Some text] only for values built
   entirely from VNil/VBool/VInt/VFloat/VString/VKeyword/VSymbol/VPair/
   VVector/VMap/VSet — data all the way down. Anything carrying code, a
   captured environment, or a handle (VClosure, VThunk, VBuiltin, VCapability,
   VEnvMap, VBytecode) makes the WHOLE containing value non-data: encoding
   returns [None]. The persistent store holds data; code values are
   process-local (see store.ml's store_object).

   Grammar (one value = one line; exactly one space between tokens, no
   trailing whitespace, no newline dependence):
     nil                    VNil
     #t / #f                VBool
     (i 42)                 VInt      — decimal, OCaml int_of_string/string_of_int
     (f 0x1.8p+1)           VFloat    — "%h" hex float; nan/inf/-inf special-cased
     (s "...")               VString   — quoted; backslash, the quote char,
                                          and bytes <0x20/0x7f escape as xHH
     (k "...")               VKeyword  — quoted (a keyword's name is defense-in-
                                          depth quoted like a string: the reader
                                          restricts source keywords to a safe
                                          character set, but nothing stops a
                                          future builtin from building one from
                                          an arbitrary string, and quoting is
                                          free)
     (y "...")               VSymbol   — quoted, same reasoning as keywords
     (p CAR CDR)             VPair     — both sides encoded; need not be a
                                          proper list
     (v E1 E2 ...)           VVector   — order preserved, "(v)" if empty
     (m (K V) (K V) ...)     VMap      — entries sorted by encoded-key byte
                                          string ascending (String.compare);
                                          "(m)" if empty
     (t E1 E2 ...)           VSet      — elements sorted by encoded-element
                                          byte string ascending; "(t)" if empty

   [decode_value] is a total inverse on encoder output: malformed or
   unrecognized input returns [None] (defense in depth — callers already
   treat [None] as a cache miss). *)

open Types

(* ---- String quoting (bytes, not code points: safe for arbitrary UTF-8 —
   bytes >= 0x80 pass through raw and reassemble the same UTF-8 sequence) ---- *)

let quote_string (s : string) : string =
  let buf = Buffer.create (String.length s + 2) in
  Buffer.add_char buf '"';
  String.iter (fun c ->
    let code = Char.code c in
    if c = '\\' then Buffer.add_string buf "\\\\"
    else if c = '"' then Buffer.add_string buf "\\\""
    else if code < 0x20 || code = 0x7f then
      Buffer.add_string buf (Printf.sprintf "\\x%02x" code)
    else Buffer.add_char buf c)
    s;
  Buffer.add_char buf '"';
  Buffer.contents buf

(* Parses a quoted string starting at [s.[start]] = '"'. Returns the decoded
   content and the index just past the closing quote, or [None] if [start]
   is not a quote or the string is unterminated/malformed. Exposed so
   store.ml's trace codec (a distinct, bespoke line format — cell-ids and
   hashes, not a Types.value) can reuse the same escaping rules. *)
let parse_quoted_string (s : string) (start : int) : (string * int) option =
  let len = String.length s in
  if start >= len || s.[start] <> '"' then None
  else
    let buf = Buffer.create 16 in
    let rec loop i =
      if i >= len then None
      else match s.[i] with
        | '"' -> Some (Buffer.contents buf, i + 1)
        | '\\' ->
            if i + 1 >= len then None
            else (match s.[i + 1] with
                  | '\\' -> Buffer.add_char buf '\\'; loop (i + 2)
                  | '"' -> Buffer.add_char buf '"'; loop (i + 2)
                  | 'x' ->
                      if i + 3 >= len then None
                      else
                        let hex = String.sub s (i + 2) 2 in
                        (match int_of_string_opt ("0x" ^ hex) with
                         | Some code -> Buffer.add_char buf (Char.chr code); loop (i + 4)
                         | None -> None)
                  | _ -> None (* unknown escape — malformed, not a valid encoder output *))
        | c -> Buffer.add_char buf c; loop (i + 1)
    in
    loop (start + 1)

(* ---- Floats: bit-exact round trip via OCaml's %h/float_of_string pair,
   with nan/inf/-inf special-cased to fixed tokens (merges NaN payloads).
   The spelling is Types.canonical_float_string — the SAME function
   hash_value uses — so content identity and on-disk bytes can never
   disagree about float equality. ---- *)

let encode_float (f : float) : string = canonical_float_string f

let decode_float (s : string) : float option =
  match s with
  | "nan" -> Some Float.nan
  | "inf" -> Some Float.infinity
  | "-inf" -> Some Float.neg_infinity
  | _ -> (try Some (float_of_string s) with _ -> None)

(* ---- Encoder ---- *)

let wrap (tag : string) (parts : string list) : string =
  match parts with
  | [] -> "(" ^ tag ^ ")"
  | _ -> "(" ^ tag ^ " " ^ String.concat " " parts ^ ")"

(* [None] if any leaf (or any nested element) is non-data — a single
   non-data leaf makes the whole containing value non-data. *)
let rec encode (v : value) : string option =
  match v with
  | VNil -> Some "nil"
  | VBool true -> Some "#t"
  | VBool false -> Some "#f"
  | VInt n -> Some (wrap "i" [string_of_int n])
  | VFloat f -> Some (wrap "f" [encode_float f])
  | VString s -> Some (wrap "s" [quote_string s])
  | VKeyword k -> Some (wrap "k" [quote_string k])
  | VSymbol s -> Some (wrap "y" [quote_string s])
  | VPair (car, cdr) ->
      (match encode car, encode cdr with
       | Some c, Some d -> Some (wrap "p" [c; d])
       | _ -> None)
  | VVector vs -> encode_list_opt (Array.to_list vs) |> Option.map (wrap "v")
  | VMap kvs ->
      let encoded =
        List.map (fun (k, v) -> (encode k, encode v)) kvs
      in
      if List.exists (fun (k, v) -> k = None || v = None) encoded then None
      else
        let pairs = List.map (fun (k, v) -> (Option.get k, Option.get v)) encoded in
        (* stable_sort: VMap is an assoc list that tolerates duplicate keys;
           stability makes the duplicate-key entry order deterministic across
           OCaml stdlib versions (List.sort's tie-breaking is unspecified). *)
        let sorted = List.stable_sort (fun (k1, _) (k2, _) -> String.compare k1 k2) pairs in
        Some (wrap "m" (List.map (fun (k, v) -> "(" ^ k ^ " " ^ v ^ ")") sorted))
  | VSet vs ->
      (match encode_list_opt vs with
       | None -> None
       | Some parts -> Some (wrap "t" (List.stable_sort String.compare parts)))
  (* Non-data: code, captured environments, or handles. Process-local only. *)
  | VClosure _ | VBuiltin _ | VCapability _ | VThunk _ | VEnvMap _ | VBytecode _ -> None

and encode_list_opt (vs : value list) : string list option =
  List.fold_right (fun v acc ->
    match acc, encode v with
    | Some rest, Some s -> Some (s :: rest)
    | _ -> None)
    vs (Some [])

(* ---- Decoder ----
   A hand-rolled recursive-descent parser matching the encoder's grammar
   exactly: every complete encoding is either a bare atom (nil/#t/#f) or a
   balanced "(tag ...)" form, so no encoding is ever a proper prefix of
   another — parsing never needs backtracking. *)

let expect_char (s : string) (i : int) (c : char) : int option =
  if i < String.length s && s.[i] = c then Some (i + 1) else None

let expect_lit (s : string) (i : int) (lit : string) : int option =
  let l = String.length lit in
  if i + l <= String.length s && String.sub s i l = lit then Some (i + l) else None

(* Reads raw text up to (not including) the next ')', used for atoms whose
   own text can never contain '(' or ')' (ints, hex floats, nan/inf/-inf). *)
let read_until_close (s : string) (i : int) : (string * int) option =
  match String.index_from_opt s i ')' with
  | Some k -> Some (String.sub s i (k - i), k + 1)
  | None -> None

let rec parse (s : string) (i : int) : (value * int) option =
  let len = String.length s in
  if i >= len then None
  else match s.[i] with
    | 'n' -> (match expect_lit s i "nil" with Some j -> Some (VNil, j) | None -> None)
    | '#' ->
        if i + 1 < len && s.[i + 1] = 't' then Some (VBool true, i + 2)
        else if i + 1 < len && s.[i + 1] = 'f' then Some (VBool false, i + 2)
        else None
    | '(' ->
        if i + 1 >= len then None
        else
          let tag = s.[i + 1] in
          let j = i + 2 in
          (match tag with
           | 'i' ->
               (match expect_char s j ' ' with
                | None -> None
                | Some j ->
                    (match read_until_close s j with
                     | None -> None
                     | Some (tok, next) ->
                         (match int_of_string_opt tok with
                          | Some n -> Some (VInt n, next)
                          | None -> None)))
           | 'f' ->
               (match expect_char s j ' ' with
                | None -> None
                | Some j ->
                    (match read_until_close s j with
                     | None -> None
                     | Some (tok, next) ->
                         (match decode_float tok with
                          | Some f -> Some (VFloat f, next)
                          | None -> None)))
           | 's' -> parse_quoted_ctor s j (fun str -> VString str)
           | 'k' -> parse_quoted_ctor s j (fun str -> VKeyword str)
           | 'y' -> parse_quoted_ctor s j (fun str -> VSymbol str)
           | 'p' ->
               (match expect_char s j ' ' with
                | None -> None
                | Some j ->
                    (match parse s j with
                     | None -> None
                     | Some (car, j) ->
                         (match expect_char s j ' ' with
                          | None -> None
                          | Some j ->
                              (match parse s j with
                               | None -> None
                               | Some (cdr, j) ->
                                   (match expect_char s j ')' with
                                    | Some next -> Some (VPair (car, cdr), next)
                                    | None -> None)))))
           | 'v' -> parse_seq s j (fun lst -> VVector (Array.of_list lst))
           | 't' -> parse_seq s j (fun lst -> VSet lst)
           | 'm' -> parse_map s j
           | _ -> None)
    | _ -> None

and parse_quoted_ctor (s : string) (j : int) (ctor : string -> value) : (value * int) option =
  match expect_char s j ' ' with
  | None -> None
  | Some j ->
      (match parse_quoted_string s j with
       | None -> None
       | Some (content, j) ->
           (match expect_char s j ')' with
            | Some next -> Some (ctor content, next)
            | None -> None))

(* [j] points just past the tag char, i.e. at ')' (empty) or ' ' (nonempty). *)
and parse_seq (s : string) (j : int) (ctor : value list -> value) : (value * int) option =
  let len = String.length s in
  if j < len && s.[j] = ')' then Some (ctor [], j + 1)
  else
    match expect_char s j ' ' with
    | None -> None
    | Some j ->
        let rec loop j acc =
          match parse s j with
          | None -> None
          | Some (v, j) ->
              if j < len && s.[j] = ')' then Some (List.rev (v :: acc), j + 1)
              else
                (match expect_char s j ' ' with
                 | Some j -> loop j (v :: acc)
                 | None -> None)
        in
        (match loop j [] with
         | None -> None
         | Some (lst, next) -> Some (ctor lst, next))

and parse_map (s : string) (j : int) : (value * int) option =
  let len = String.length s in
  if j < len && s.[j] = ')' then Some (VMap [], j + 1)
  else
    match expect_char s j ' ' with
    | None -> None
    | Some j ->
        let parse_entry j =
          match expect_char s j '(' with
          | None -> None
          | Some j ->
              (match parse s j with
               | None -> None
               | Some (k, j) ->
                   (match expect_char s j ' ' with
                    | None -> None
                    | Some j ->
                        (match parse s j with
                         | None -> None
                         | Some (v, j) ->
                             (match expect_char s j ')' with
                              | Some next -> Some ((k, v), next)
                              | None -> None))))
        in
        let rec loop j acc =
          match parse_entry j with
          | None -> None
          | Some (kv, j) ->
              if j < len && s.[j] = ')' then Some (List.rev (kv :: acc), j + 1)
              else
                (match expect_char s j ' ' with
                 | Some j -> loop j (kv :: acc)
                 | None -> None)
        in
        (match loop j [] with
         | None -> None
         | Some (kvs, next) -> Some (VMap kvs, next))

let encode_value (v : value) : string option = encode v

let decode_value (s : string) : value option =
  match parse s 0 with
  | Some (v, next) when next = String.length s -> Some v
  | _ -> None
