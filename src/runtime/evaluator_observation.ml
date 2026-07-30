open Pp_kernel
open Core_model

let string_argument head = function
  | VString value -> value
  | value ->
      failwith
        (Printf.sprintf "$%s expects a string argument, got %s"
           head (Presentation.string_of_value value))

let config_key = function
  | VString value | VKeyword value -> value
  | value ->
      failwith
        (Printf.sprintf "$config expects a string or keyword key, got %s"
           (Presentation.string_of_value value))

let evaluated (operations : Evaluator_scope.operations) expression env =
  operations.force (operations.eval expression env)

let default (operations : Evaluator_scope.operations) result fallback env k =
  match result, fallback with
  | Some value, _ -> k value
  | None, Some expression -> operations.eval_tail expression env k
  | None, None -> k VNil

let eval (operations : Evaluator_scope.operations) kind arguments env k =
  let unary head read = function
    | [argument] ->
        let argument = string_argument head (evaluated operations argument env) in
        k (read argument)
    | _ -> failwith (Printf.sprintf "$%s expects one argument" head)
  in
  match kind with
  | File -> unary "file" Observation.read_file arguments
  | Tree -> unary "tree" Observation.read_tree arguments
  | Secret -> unary "secret" Observation.read_secret arguments
  | Stat -> unary "stat" Observation.read_stat arguments
  | Probe ->
      (match arguments with
       | [name] ->
           let name = string_argument "probe" (evaluated operations name env) in
           (match Observation.read_probe name with
            | Some value -> k value
            | None -> failwith ("$probe: unregistered probe: " ^ name))
       | _ -> failwith "$probe expects one argument")
  | Argv ->
      (match arguments with
       | [] -> k (Observation.read_argv ())
       | _ -> failwith "$argv expects no arguments")
  | Env ->
      (match arguments with
       | [name] ->
           let name = string_argument "env" (evaluated operations name env) in
           default operations (Observation.read_env name) None env k
       | [name; fallback] ->
           let name = string_argument "env" (evaluated operations name env) in
           default operations (Observation.read_env name) (Some fallback) env k
       | _ -> failwith "$env expects one or two arguments")
  | Config ->
      (match arguments with
       | [key] ->
           let key = config_key (evaluated operations key env) in
           default operations (Observation.read_config key) None env k
       | [key; fallback] ->
           let key = config_key (evaluated operations key env) in
           default operations (Observation.read_config key) (Some fallback) env k
       | _ -> failwith "$config expects one or two arguments")
