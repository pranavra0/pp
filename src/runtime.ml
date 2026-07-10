(* pp runtime — shared mutable state used by both backends *)

open Types

(* Handler stack for algebraic effects *)
let handler_stack : (string * (value list -> value)) list ref = ref []

(* Current capability set (for effectful blocks) *)
let current_capabilities : capability list ref = ref []

(* ReaderT-style ambient config stack *)
let config_stack : value list ref = ref []

(* Content-addressed thunk store *)
let thunk_store : (string, thunk) Hashtbl.t = Hashtbl.create 1024

(* Initial capabilities from --grant (set by main.ml before init) *)
let initial_capabilities : capability list ref = ref []
