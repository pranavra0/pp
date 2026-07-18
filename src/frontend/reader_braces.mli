open Pp_kernel
(* pp brace reader — the brace surface syntax (SPEC Appendix B), parsing to the
   IDENTICAL `Core_model.expr` the s-expression reader produces for the equivalent
   program.  The .mli exposes only what callers actually use. *)

type fseg = FLit of string | FHole of string

type btok =
  | TLParen | TRParen
  | TLBracket | TRBracket
  | TLBrace | TRBrace
  | TComma | TSemi | TNewline
  | TString of string
  | TFString of fseg list
  | TInt of int
  | TFloat of float
  | TName of string
  | TKeyword of string
  | TColon
  | TEOF

type tok = { t : btok; tline : int; glued : bool }

type state

val create : ?source:string -> unit -> state
val read : state -> string -> Core_model.expr list

val is_name_char : char -> bool

val lex : file:string -> string -> tok list

val read_string : ?source:string -> string -> Core_model.expr list

val read_dispatch :
  ?source:string -> path:string -> string -> Core_model.expr list

val file_uses_braces : string -> bool

val needs_more_input : ?source:string -> string -> bool
