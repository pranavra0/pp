(* node — shared node-boundary checks and the one rebuilder.

   The key skeleton itself lives in the kernel's [Hasher] module, so both
   backends consume the same construction without making this runtime module
   part of the keying layer. *)
val fv_hash : name:string -> Types.value -> (Types.value -> Types.value) -> string
val unbound_fv_hash : name:string -> string

val check_type : Types.value -> Types.expr -> (string * int) option -> unit
val enforce_type : Types.thunk -> Types.value -> unit
val replay_node_reads : Types.thunk -> (Types.thunk -> string) -> unit
val serve_hit : t:Types.thunk -> Store.hit_result -> Types.value option
val run_node_body : key:string -> run:(unit -> Types.value) -> Types.thunk -> Types.value