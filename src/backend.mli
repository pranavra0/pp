(* pp backend — the record of init-time hook functions that break
   compile-order cycles.

   Replaces the scattered forward-reference cells with a single mutable
   record: every backend engine hook (force/eval/apply/node-key/
   run-node/expand) is a field here, installed by the init that owns it
   and read by the module that needs it. *)

type t = {
  mutable force : Types.value -> Types.value;
  mutable realpath : string -> string;
  mutable eval : Types.expr -> Types.env -> Types.value;
  mutable apply : Types.value -> Types.value list -> Types.env -> Types.value;
  mutable node_key_of : Types.thunk -> string;
  mutable run_node_body :
    key:string -> run:(unit -> Types.value) -> Types.thunk -> Types.value;
  mutable resolve_if_hit : Types.thunk -> string -> bool;
  mutable expand_toplevel : Types.expr list -> Types.expr list;
  mutable macro_reset : unit -> unit;
  mutable get_unix_time : unit -> float;
  mutable cap_write_secret : string -> string -> unit;
  mutable cap_read_secret : string -> string;
  mutable home_dir : unit -> string;
}

(* The single global record. Defaults are no-ops/identity hooks so a build
   that never links an owner degrades rather than crashes. *)
val r : t
