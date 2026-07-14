(* hasher — the identity kernel's public face (MASTER-PLAN A′4 seam).

   All hashing logic lives in [Types] (SHA-256 via Cryptokit); this module is
   the thin, named re-export every other layer hashes through. The .mli fixes
   that surface so the identity boundary is explicit: content-addressing (LAW
   19/20) enters the rest of the system only through these functions, and the
   authority/sealed guards ([contains_authority]/[contains_sealed]) that gate
   the node boundary have exactly one spelling. *)

val hash_string : string -> string
val hash_concat : string list -> string
val hash_expr : Types.expr -> string
val hash_value : Types.value -> string
val hash_capability : Types.capability -> String.t
val hash_bindings_flat : (string * Types.value) list -> string
val contains_authority : Types.value -> bool
val contains_sealed : Types.value -> bool
