(* pp hasher — thin re-export; all hashing logic lives in Types.ml
   v2 should upgrade to SHA-256. *)

open Types

let hash_string = hash_string
let hash_concat = hash_concat
let hash_expr = hash_expr
let hash_value = hash_value
let hash_capability = hash_capability
let hash_bindings_flat = hash_bindings_flat
