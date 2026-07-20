(* cell — the closed variant of observation-cell kinds.

   [Cell.t] is the single source of truth for "what kinds of world-reads pp
   can record"; [Surface_tables.surface_decision] matches over this type
   exhaustively to derive each kind's surface story. The constructors are
   intentionally public: the runtime builds them and the surface layer
   matches on them exhaustively — that exhaustiveness is the ratchet (adding
   a constructor without deciding its surface story fails the build), so
   hiding the constructors would defeat it. The interface exists to fix the
   boundary (only [t], [serialize], [parse] cross it) so no future code
   grows a private cell helper that other modules reach into. *)

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
  | Probe of string
  | Sealed of string
  | Domain of { name : string; sub : string; }
  | Unknown of string

(* Canonical wire spelling of a cell id (e.g. [File "p"] -> "file:p"). *)
val serialize : t -> string

(* Inverse of [serialize]; unrecognized spellings become [Unknown]. *)
val parse : string -> t
