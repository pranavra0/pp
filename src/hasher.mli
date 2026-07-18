(* hasher — the low-level content-addressing primitives.

   SHA-256 and the injective length-framed join, at the bottom of the
   dependency graph so the early-compiled [Capability] module (which hashes
   an abstract type) shares the single definition without a cycle.  The
   higher-level [Identity.hash_value]/[Identity.hash_expr] are NOT re-exported
   here: they live in [Identity], which depends on the recursive value/expr
   model. *)
val hex_encode : string -> string
val hash_string : string -> string
val hash_concat : string list -> string
val node_key_skeleton : expr_hash:string -> string list -> string
