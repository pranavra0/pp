type location = Source_range.t

type diagnostic = {
  code : string option;
  message : string;
  location : location option;
  related : (string * location) list;
}

type lsp_position = { line : int; character : int }
type lsp_range = { start : lsp_position; end_ : lsp_position }
type lsp_related = { message : string; range : lsp_range }
type lsp_diagnostic = {
  range : lsp_range option;
  severity : int;
  code : string option;
  message : string;
  related : lsp_related list;
}

type reader_error =
  | Syntax of diagnostic
  | Incomplete of diagnostic

type evaluator_error = diagnostic
type capability_error =
  | Denied of diagnostic
  | Authority_escape of diagnostic
type store_error =
  | Read_failed of { path : string; message : string }
  | Write_failed of { path : string; message : string }
  | Corrupt of { path : string; message : string }
type transport_error =
  | Integrity of { artifact : string; message : string }
  | Unavailable of { peer : string; message : string }
type command_error = Invalid_argument of string | Missing_input of string
type operational_error =
  | Io of { operation : string; message : string }
  | Child of { pid : int; status : string }
  | Signaled of { signal : int }
  | Interrupted

type t =
  | Reader of reader_error
  | Evaluator of evaluator_error
  | Capability of capability_error
  | Store of store_error
  | Transport of transport_error
  | Command of command_error
  | Operational of operational_error

type cache_decision = Cacheable | Do_not_cache
val cache_decision : t -> cache_decision
val diagnostic : ?code:string -> ?location:location ->
  ?related:(string * location) list -> string -> diagnostic
val diagnostic_of_t : t -> diagnostic option
val to_lsp : diagnostic -> lsp_diagnostic
val with_location : location option -> t -> t
val string_of_t : t -> string

exception Error of t
exception Reader_incomplete of reader_error
exception Pp_exit of int

val eval : ?location:location -> string -> 'a
val capability : string -> 'a
val authority_escape : string -> 'a
val reader : ?location:location -> string -> 'a
val incomplete : ?location:location -> string -> 'a
val command : string -> 'a
