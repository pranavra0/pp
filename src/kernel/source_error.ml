(* Errors crossing pp's module boundaries.  Internal OCaml exceptions are
   converted at the boundary that can give them a useful location or policy. *)

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
  | Some range ->
      let position = Source_range.start range in
      Printf.sprintf " at %s:%d" (Source_range.source range) position.line

let diagnostic ?code ?location ?(related = []) message =
  { code; message; location; related }

let lsp_range_of_source_range range =
  let start = Source_range.start range and end_ = Source_range.end_ range in
  { start = { line = start.line - 1; character = start.column - 1 };
    end_ = { line = end_.line - 1; character = end_.column - 1 } }

let to_lsp diagnostic =
  { range = Option.map lsp_range_of_source_range diagnostic.location;
    severity = 1;
    code = diagnostic.code;
    message = diagnostic.message;
    related = List.map (fun (message, range) ->
      { message; range = lsp_range_of_source_range range }) diagnostic.related }

let diagnostic_of_t = function
  | Reader (Syntax diagnostic | Incomplete diagnostic)
  | Evaluator diagnostic
  | Capability (Denied diagnostic | Authority_escape diagnostic) -> Some diagnostic
  | Store _ | Transport _ | Command _ | Operational _ -> None

let string_of_reader_error = function
  | Syntax { message; location; _ } | Incomplete { message; location; _ } ->
      message ^ location_suffix location

let string_of_t = function
  | Reader error -> string_of_reader_error error
  | Evaluator { message; location; _ } -> message ^ location_suffix location
  | Capability (Denied { message; location; _ }
              | Authority_escape { message; location; _ }) ->
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
  | Reader (Syntax ({ location = None; _ } as error)) ->
      Reader (Syntax { error with location })
  | Reader (Incomplete ({ location = None; _ } as error)) ->
      Reader (Incomplete { error with location })
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
  raise (Error (Evaluator (diagnostic ~code:"runtime-error" ?location message)))

let capability message =
  raise (Error (Capability (Denied (diagnostic ~code:"capability-denied" message))))
let authority_escape message =
  raise (Error (Capability
    (Authority_escape (diagnostic ~code:"authority-escape" message))))

let reader ?location message =
  raise (Error (Reader
    (Syntax (diagnostic ~code:"syntax-error" ?location message))))

let incomplete ?location message =
  raise (Reader_incomplete
    (Incomplete (diagnostic ~code:"incomplete-input" ?location message)))

let command message = raise (Error (Command (Invalid_argument message)))
