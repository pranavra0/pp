(* Errors crossing pp's module boundaries.  Internal OCaml exceptions are
   converted at the boundary that can give them a useful location or policy. *)

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

type command_error =
  | Invalid_argument of string
  | Missing_input of string

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

(* This is deliberately exhaustive.  A capability error is authority
   dependent and must never become a persistent node failure; every other
   boundary error has the ordinary evaluative/recoverable policy. *)
type cache_decision = Cacheable | Do_not_cache

let cache_decision = function
  | Capability _ -> Do_not_cache
  | Reader _ | Evaluator _ | Store _ | Transport _ | Command _
  | Operational _ -> Cacheable

let location_suffix = function
  | None -> ""
  | Some (file, line) -> Printf.sprintf " at %s:%d" file line

let string_of_reader_error = function
  | Syntax { message; location } | Incomplete { message; location } ->
      message ^ location_suffix location

let string_of_t = function
  | Reader error -> string_of_reader_error error
  | Evaluator { message; location } -> message ^ location_suffix location
  | Capability (Denied { message; location }
              | Authority_escape { message; location }) ->
      message ^ location_suffix location
  | Store (Read_failed { path; message } | Write_failed { path; message }
         | Corrupt { path; message }) ->
      Printf.sprintf "store: %s: %s" path message
  | Transport (Integrity { artifact; message } | Unavailable { peer = artifact; message }) ->
      Printf.sprintf "transport: %s: %s" artifact message
  | Command (Invalid_argument message | Missing_input message) -> message
  | Operational (Io { operation; message }) -> operation ^ ": " ^ message
  | Operational (Child { pid; status }) ->
      Printf.sprintf "child %d: %s" pid status
  | Operational (Signaled { signal }) ->
      Printf.sprintf "process terminated by signal %d" signal
  | Operational Interrupted -> "operation interrupted"

let with_location location = function
  | Reader (Syntax { message; location = None }) ->
      Reader (Syntax { message; location })
  | Reader (Incomplete { message; location = None }) ->
      Reader (Incomplete { message; location })
  | Evaluator ({ location = None; _ } as error) ->
      Evaluator { error with location }
  | Capability (Denied ({ location = None; _ } as error)) ->
      Capability (Denied { error with location })
  | Capability (Authority_escape ({ location = None; _ } as error)) ->
      Capability (Authority_escape { error with location })
  | error -> error

exception Error of t
exception Reader_incomplete of reader_error
exception Pp_exit of int

let () = Printexc.register_printer (function
  | Error error -> Some (string_of_t error)
  | Reader_incomplete error -> Some (string_of_reader_error error)
  | _ -> None)

let eval ?location message =
  raise (Error (Evaluator { message; location }))

let capability message =
  raise (Error (Capability (Denied { message; location = None })))
let authority_escape message =
  raise (Error (Capability (Authority_escape { message; location = None })))

let reader ?location message =
  raise (Error (Reader (Syntax { message; location })))

let incomplete ?location message =
  raise (Reader_incomplete (Incomplete { message; location }))

let command message = raise (Error (Command (Invalid_argument message)))
