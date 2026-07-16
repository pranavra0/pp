(* pp store codec — one canonical, versioned, byte-stable TEXT encoding for
   DATA values. The store must be readable across OS/arch/compiler, which
   OCaml Marshal is not.

   THE NON-DATA LAW: [encode_value] returns [Some text] only for values
   built entirely from data. Anything carrying code, a captured environment,
   a handle, or a sealed secret makes the whole containing value non-data:
   encoding returns [None]. *)

(* Quote a string for the codec grammar: backslash, the quote char, and
   bytes < 0x20 / 0x7f escape as xHH. Also reused by cap_token.ml and
   store.ml's trace-line codec. *)
val quote_string : string -> string

(* Parse a quoted string starting at [s.[start]] = '"'. Returns the
   decoded content and the index just past the closing quote, or [None]
   on malformed input. Also reused by store.ml's trace-line codec. *)
val parse_quoted_string : string -> int -> (string * int) option

(* Bit-exact float encoding via %h, with nan/inf/-inf as fixed tokens. *)
val encode_float : float -> string

(* [encode]/[parse] are internal to the codec (the value grammar); only the
   string-quoting helpers and the [encode_value]/[decode_value] entry points
   are reused elsewhere. *)
val expect_char : string -> int -> char -> int option
val expect_lit : string -> int -> string -> int option
val bind : 'a option -> ('a -> 'b option) -> 'b option
val ( >>= ) : 'a option -> ('a -> 'b option) -> 'b option

(* The public entry points. *)
val encode_value : Types.value -> string option
val decode_value : string -> Types.value option
