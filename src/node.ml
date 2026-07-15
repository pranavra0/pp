(* node — the node-key skeleton and the one rebuilder. *)

open Types

let node_key_skeleton ~(expr_hash : string) (fv_hashes : string list) : string =
  hash_concat (["node-key"; expr_hash] @ fv_hashes)

let fv_hash ~(name : string) (v : value) (force : value -> value) : string =
  match force v with
  | fv ->
      if contains_authority fv then
        raise (Capability_error
          (Printf.sprintf
             "node: free variable '%s' may not be or contain a %s" name
             (if contains_sealed fv then "sealed value" else "capability")));
      hash_concat ["fv"; name; hash_value fv]
  | exception e ->
      (match e with
       | Capability_error _ -> raise e
       | _ -> hash_concat ["fv"; name; hash_value v])

let unbound_fv_hash ~(name : string) : string =
  hash_concat ["fv-unbound"; name]