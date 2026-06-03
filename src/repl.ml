(* pp REPL — Read-Eval-Print Loop *)

open Types
open Reader
open Evaluator

(* Global environment for REPL *)
let global_env : env ref = ref []

(* Initialize REPL *)
let init () =
  Evaluator.init ();
  global_env := Primitives.initial_env ()

(* Process a single expression and return the result *)
let process_expr (e : expr) : value =
  match e with
  | EDef (name, params, body) ->
      let closure = make_closure ~name:(Some name) params body global_env in
      global_env := extend_env !global_env name closure;
      closure
  | EDefFexpr (name, params, body) ->
      let fexpr = make_fexpr ~name:(Some name) params body global_env in
      global_env := extend_env !global_env name fexpr;
      fexpr
  | _ ->
      let v = eval e !global_env in
      force v

(* Execute a source string (multiple expressions) *)
let execute_string (source : string) : value list =
  init ();  (* always init *)
  let exprs = read_string source in
  List.map (fun e ->
    let result = process_expr e in
    result
  ) exprs

(* Execute a source file *)
let execute_file (path : string) : value list =
  let ch = open_in path in
  let source = really_input_string ch (in_channel_length ch) in
  close_in ch;
  execute_string source

(* REPL loop *)
let repl () =
  init ();
  Printf.printf "pp v0.1.0 — lazy, pure-by-default, content-addressed Lisp\n";
  Printf.printf "Type 'exit' or Ctrl-D to quit.\n\n%!";
  let rec loop () =
    try
      Printf.printf "pp> %!";
      let line = read_line () in
      if line = "exit" || line = "quit" then
        Printf.printf "bye.\n%!"
      else if String.trim line = "" then
        loop ()
      else
        (try
           let exprs = read_string line in
           List.iter (fun e ->
             let result = process_expr e in
             Printf.printf "%s\n%!" (string_of_value result)
           ) exprs
         with
         | Failure msg -> Printf.printf "Error: %s\n%!" msg
         | Sys_error msg -> Printf.printf "Error: %s\n%!" msg
         | End_of_file -> raise End_of_file
         | e -> Printf.printf "Error: %s\n%!" (Printexc.to_string e));
        loop ()
    with End_of_file ->
      Printf.printf "\nbye.\n%!"
  in
  loop ()
