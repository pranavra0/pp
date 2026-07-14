(* surface_tables — the closed surface sets as data (MASTER-PLAN A′1/A′4 seam).

   The three closed tables and the exhaustive [Cell.t] ratchet. The .mli fixes
   the boundary: consumers (both readers, the `needs` desugar, lint, error
   messages, the SPEC-drift test) see the tables, the lookup/arity helpers, the
   SPEC renderer, and the ratchet — but NOT the render helpers ([render_tmpl] &
   friends), which are internal to [render_spec_tables]. See src/surface_tables.ml
   for the rationale on why constructors stay public (both readers interpret the
   [tmpl] shape; the exhaustive [surface_decision] is the compile-time ratchet). *)

(* ---- observation heads ($KIND) ---------------------------------------- *)

type tmpl =
    Prim of string
  | Arg of int
  | App of tmpl list
  | If of tmpl * tmpl * tmpl
  | Perform of string * tmpl list      (* (perform EFFECT args…) — a traced observation *)

type obs_head = {
  head : string;
  min_args : int;
  max_args : int;
  qq_legal : bool;
  doc : string;
  tmpl : int -> tmpl;
}

val obs_heads : obs_head list
val find_head : string -> obs_head option
val known_heads_message : unit -> string
val check_arity : obs_head -> int -> (unit, string) result

(* ---- with{} clauses --------------------------------------------------- *)

type with_wrapper = WCaps | WConfig | WHandlers

type with_clause = {
  clause : string;
  wrapper : with_wrapper;
  colon : bool;
  wdoc : string;
}

val with_clauses : with_clause list
val find_with_clause : string -> with_clause option
val with_clauses_message : unit -> string

(* ---- grant-descriptor sugar ------------------------------------------- *)

type grant_sugar = {
  descriptor : string;
  restrict_mode : string;
  gdoc : string;
}

val grant_sugar : grant_sugar list
val find_grant_sugar : string -> grant_sugar option

(* ---- SPEC rendering (A′2) --------------------------------------------- *)

(* Emits exactly the text between docs/SPEC.md's generated-block markers;
   tests/067 diffs it. The render_* helpers it uses are module-private. *)
val render_spec_tables : unit -> string

(* ---- the exhaustive ratchet over Cell.t ------------------------------- *)

type surface_story =
    Surfaced of string
  | RuntimeRecorded of string
  | Whitelisted of string

(* Exhaustive over every [Cell.t] constructor — the compile-time ratchet that
   forces a surface decision for any new cell kind (A′1). *)
val surface_decision : Cell.t -> surface_story
