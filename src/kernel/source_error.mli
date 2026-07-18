type location = string * int

type reader_error =
  | Syntax of { message : string; location : location option }
  | Incomplete of { message : string; location : location option }

type evaluator_error = { message : string; location : location option }
type capability_error =
  | Denied of { message : string; location : location option }
  | Authority_escape of { message : string; location : location option }
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
