(* node — the node-key skeleton and the one rebuilder.

   Key skeleton — shared by both backends so the byte-identical format has
   one definition.
     
   [node_key_skeleton ~expr_hash fv_hashes] builds the node-key hash list
   from the expression hash and the list of pre-computed free-variable
   hashes (each produced by [fv_hash] or [unbound_fv_hash]).

   [fv_hash ~name v force] forces [v] via the supplied [force] function,
   checks the LAW 20 node-boundary ban (capability/sealed), and returns the
   free-variable hash entry.  If forcing raises, [Capability_error] is
   re-raised; any other exception falls through to hashing the unforced
   value (preserving existing behaviour).

   Rebuilder — the body evaluation, trace caching, and result-ban logic,
   moved here from evaluator.ml so the one copy is findable. *)

val node_key_skeleton : expr_hash:string -> string list -> string
val fv_hash : name:string -> Types.value -> (Types.value -> Types.value) -> string
val unbound_fv_hash : name:string -> string

val check_type : Types.value -> Types.expr -> (string * int) option -> unit
val replay_node_reads : Types.thunk -> (Types.thunk -> string) -> unit
val serve_hit : t:Types.thunk -> Store.hit_result -> Types.value option
val run_node_body : key:string -> run:(unit -> Types.value) -> Types.thunk -> Types.value