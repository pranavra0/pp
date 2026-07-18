(* Structured language and source errors. *)

(* Capability denials are distinct because node evaluation must not cache them. *)
exception Capability_error of string
let () = Printexc.register_printer (function
  | Capability_error msg -> Some msg
  | _ -> None)

(* Deliberate termination bypasses node failure caching and error decoration. *)
exception Pp_exit of int

(* Incomplete input is distinct so the REPL can request another line. *)
exception Reader_incomplete of string
let () = Printexc.register_printer (function
  | Reader_incomplete msg -> Some msg
  | _ -> None)

(* [kind] preserves whether node evaluation may cache a located failure. *)
type err_kind = Eval | Capability
exception Pp_error of { kind : err_kind; msg : string; pos : (string * int) option }
let () = Printexc.register_printer (function
  | Pp_error { msg; pos = Some (file, line); _ } ->
      Some (Printf.sprintf "%s at %s:%d" msg file line)
  | Pp_error { msg; pos = None; _ } -> Some msg
  | _ -> None)
