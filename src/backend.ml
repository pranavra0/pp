(* pp backend — the one record of init-time hook functions that break
   compile-order cycles.

   Replaces the scattered forward-reference cells in primitives.ml, the
   force hook in runtime.ml, and the per-backend node/j_run hooks with a
   single mutable record: every backend engine hook (force/eval/apply/
   node-key/run-node/expand) is a field here, installed by the init that
   owns it and read by the module that needs it — instead of fourteen
   `*_ref` cells spread across three files, each with its own
   "not initialized" stub, plus runtime.force_hook (always set to the same
   function as force, so folded into the one `force` field).

   Compiled immediately after `types.ml` and depending on `Types` ONLY:
   every hook's type is Types-shaped (value/expr/env/thunk), so this
   module introduces no new dependency and sits below every consumer —
   primitives, runtime, scheduler, evaluator, macro, remote, main.
   (remote_dispatch stays in scheduler.ml: its type names Scheduler.job,
   so moving it here would make Backend depend on Scheduler while
   Scheduler depends on Backend — a cycle. The one retained forward-ref
   is the price of that cycle; the rest collapse.)

   The record is mutable and per-init field-assigned, not built in one
   immutable assignment. Per-init mutation is the faithful translation of
   the old `:=` cells; the net-delete is the point (fourteen global refs
   → one record), not a timing change. A field added for convenience is
   the old refs growing back with better manners — a field must break a
   compile-order cycle. *)
open Types

type t = {
  mutable force : value -> value;
  mutable realpath : string -> string;
  mutable eval : expr -> env -> value;
  mutable apply : value -> value list -> env -> value;
  mutable node_key_of : thunk -> string;
  mutable run_node_body :
    key:string -> run:(unit -> value) -> thunk -> value;
  mutable resolve_if_hit : thunk -> string -> bool;
  mutable expand_toplevel : expr list -> expr list;
  mutable macro_reset : unit -> unit;
  mutable get_unix_time : unit -> float;
  mutable cap_write_secret : string -> string -> unit;
  mutable cap_read_secret : string -> string;
  mutable home_dir : unit -> string;
}

(* Defaults match the originals: the no-op/identity hooks keep their old
   behavior so a build that never links an owner degrades rather than
   crashes; the genuinely-required hooks fail with one clear message. *)
let r : t = {
  force = (fun v -> v);
  eval = (fun _ _ -> failwith "Backend: eval hook not installed");
  apply = (fun _ _ _ -> failwith "Backend: apply hook not installed");
  node_key_of = (fun _ -> failwith "Backend: node_key_of hook not installed");
  run_node_body =
    (fun ~key:_ ~run:_ _ -> failwith "Backend: run_node_body hook not installed");
  resolve_if_hit = (fun _ _ -> false);
  expand_toplevel = (fun exprs -> exprs);
  macro_reset = (fun () -> ());
  realpath = (fun _ ->
    failwith "Backend: realpath hook not installed");
  get_unix_time = (fun () -> 0.);
  cap_write_secret = (fun _ _ ->
    failwith "Backend: cap_write_secret hook not installed");
  cap_read_secret = (fun _ ->
    failwith "Backend: cap_read_secret hook not installed");
  home_dir = (fun () ->
    failwith "Backend: home_dir hook not installed");
}