(* cell — the closed variant of observation-cell kinds (MASTER-PLAN A′4 seam).

   [Cell.t] is the single source of truth for "what kinds of world-reads pp can
   record" (A′1 builds the surface story on top of it via
   [Surface_tables.surface_decision], an exhaustive match over this type). The
   constructors are intentionally public: the runtime builds them and the
   surface layer matches on them exhaustively — that exhaustiveness is the
   ratchet, so hiding the constructors would defeat A′1. The interface exists to
   fix the boundary (only [t], [to_string], [of_string] cross it) so no future
   code grows a private cell helper that other modules reach into. *)

type t =
    File of string
  | RuntimeFile of string
  | Tool of string
  | Tree of string
  | Stat of string
  | Env of string
  | Argv
  | Config of string
  | Handler of string
  | Proc of string
  | Probe of string
  | Sealed of string
  | Domain of { name : string; sub : string; }
  | Unknown of string

(* Canonical wire spelling of a cell id (e.g. [File "p"] -> "file:p"). *)
val to_string : t -> string

(* Inverse of [to_string]; unrecognized spellings become [Unknown]. *)
val of_string : string -> t
