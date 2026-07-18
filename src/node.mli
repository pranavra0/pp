(* node — shared node-boundary checks and the one rebuilder.

   The key skeleton itself lives in the kernel's [Hasher] module, so both
   backends consume the same construction without making this runtime module
   part of the keying layer. *)
val fv_hash : name:string -> Core_model.value -> (Core_model.value -> Core_model.value) -> string
val unbound_fv_hash : name:string -> string

val check_type : Core_model.value -> Core_model.expr -> (string * int) option -> unit
val enforce_type : Core_model.thunk -> Core_model.value -> unit
val replay_node_reads : Core_model.thunk -> (Core_model.thunk -> string) -> unit
val serve_hit : t:Core_model.thunk -> Store.hit_result -> Core_model.value option
val run_node_body : key:string -> run:(unit -> Core_model.value) -> Core_model.thunk -> Core_model.value