open Pp_kernel
open Core_model

let eval ~force ~eval ~eval_tail value arms env k =
  let rec try_arms = function
    | [] -> failwith "match failure"
    | (pattern, guard, body) :: rest ->
        (match Pattern_match.match_pattern value pattern with
         | None -> try_arms rest
         | Some bindings ->
             let arm_env = List.fold_left
               (fun env (name, value) -> Environment.extend env name value)
               env bindings
             in
             let fires =
               match guard with
               | None -> true
               | Some guard ->
                   (match force (eval guard arm_env) with
                    | VBool false | VNil -> false
                    | _ -> true)
             in
             if fires then eval_tail body arm_env k else try_arms rest)
  in
  try_arms arms
