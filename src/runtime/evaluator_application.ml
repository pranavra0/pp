open Pp_kernel
open Core_model

type continuation = value -> value

type evaluator = {
  eval_tail : expr -> env -> continuation -> value;
  force : value -> value;
  make_node :
    name:string option ->
    expr ->
    env ->
    argument_hashes:string list ->
    value;
}

let apply_tail evaluator (fn : value) (args : value list) (env : env)
    (k : continuation) : value =
  match fn with
  | VClosure { fn_name; params; body; env = closure_env; is_node } ->
      if List.length params <> List.length args then begin
        let name = match fn_name with Some name -> name | None -> "#<fn>" in
        failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d"
                    name (List.length params) (List.length args))
      end;
      let args = if is_node then List.map evaluator.force args else args in
      let env' = List.fold_left2 (fun env param arg ->
        Environment.extend env param arg
      ) !closure_env params args in
      if is_node then
        let argument_hashes = List.map Identity.hash_value args in
        k (evaluator.make_node ~name:fn_name body env' ~argument_hashes)
      else
        evaluator.eval_tail body env' k
  | VBuiltin (_, implementation) ->
      k (implementation args env)
  | _ ->
      failwith (Printf.sprintf "not a function: %s" (Presentation.string_of_value fn))

let apply evaluator fn args env =
  apply_tail evaluator fn args env Fun.id
