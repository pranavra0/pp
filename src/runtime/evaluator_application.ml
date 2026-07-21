open Pp_kernel
open Core_model

type continuation = value -> value

type evaluator = {
  eval_tail : expr -> env -> continuation -> value;
  force : value -> value;
}

let apply_tail evaluator (fn : value) (args : value list) (env : env)
    (k : continuation) : value =
  match fn with
  | VClosure { fn_name; params; body; env = closure_env; closure_kind } ->
      if List.length params <> List.length args then begin
        let name = match fn_name with Some name -> name | None -> "#<fn>" in
        failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d"
                    name (List.length params) (List.length args))
      end;
      (match closure_kind with
       | Node ->
           Evaluator_node.apply ~force:evaluator.force ~fn_name ~params ~body
             ~closure_env args k
       | Function ->
           let env' = List.fold_left2 (fun env param arg ->
             Environment.extend env param arg
           ) !closure_env params args in
           evaluator.eval_tail body env' k)
  | VBuiltin (_, implementation) ->
      k (implementation args env)
  | _ ->
      failwith (Printf.sprintf "not a function: %s" (Presentation.string_of_value fn))

let apply evaluator fn args env =
  apply_tail evaluator fn args env Fun.id
