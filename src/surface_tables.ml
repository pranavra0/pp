(* surface_tables — the closed surface sets as data (MASTER-PLAN A′1).

   The recurring defect class on this branch was the same closed list written
   out by hand in N places — the `$` observation heads in the normal reader and
   again in the quasiquote reader, the grant-descriptor sugar, the `with`-clause
   keywords, the lint whitelists, the fuzzer's generators, and SPEC. Every one
   of those hand-maintained copies drifts. This module is the fix: each closed
   set is ONE typed value here, and every other layer derives from it.

   Three tables live here:

   1. [obs_heads]      — the `$KIND(...)` observation sigils. Both readers
                         (normal and `quasiquote{}`) parse a head's arguments as
                         an ordinary expression list (A6: computed paths, not
                         string literals only) and then call the head's [lower].
   2. [with_clauses]   — the `with { caps:/config:/handlers: }` clause kinds.
   3. [grant_sugar]    — the dotted grant descriptors (`fs.read`/`fs.write`/
                         `fs.rw`) that desugar to a `cap-restrict` mode.

   And one exhaustive ratchet: [surface_decision] matches EVERY [Cell.t]
   constructor and returns that kind's surface story. Because the match is
   exhaustive (and the build runs with warnings-as-errors), adding a [Cell.t]
   constructor without deciding how — if at all — it surfaces is a COMPILE
   ERROR, not a review comment. That is the whole point: the compiler now forces
   the decision the reviewer used to have to remember. *)

(* ---- observation heads ($KIND) ---------------------------------------- *)

(* A head's lowering is a small template, not an OCaml closure — because it must
   be produced in TWO shapes: real AST nodes in the normal reader, and quoted
   list-building data in the quasiquote reader (A3 deferred `$`-head qq parity
   to A′1 precisely so the shape would live in one place). Both readers walk the
   same [tmpl] with their own interpreter, so a head added here exists in both
   with the SAME lowering by construction — no second copy to drift. *)
type tmpl =
  | Prim of string          (* a primitive symbol, e.g. "slurp" *)
  | Arg of int              (* the i-th user-supplied argument (0-based) *)
  | App of tmpl list        (* application: head then args *)
  | If of tmpl * tmpl * tmpl

type obs_head = {
  head : string;               (* the sigil name, without the leading '$' *)
  min_args : int;
  max_args : int;              (* max_int for variadic; none is variadic today *)
  qq_legal : bool;             (* may it appear inside quasiquote{}? *)
  doc : string;
  tmpl : int -> tmpl;          (* arity -> lowering template; arity pre-checked *)
}

let obs_heads : obs_head list = [
  { head = "file"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$file(path) — read a file's contents (records a file: cell)";
    tmpl = (fun _ -> App [Prim "slurp"; Arg 0]) };
  { head = "env"; min_args = 1; max_args = 2; qq_legal = true;
    doc = "$env(name[, default]) — read an environment variable (records an \
           env: cell); the optional default is used when the variable is unset";
    tmpl = (fun n -> match n with
      | 1 -> App [Prim "env-get"; Arg 0]
      | 2 -> If (App [Prim "nil?"; App [Prim "env-get"; Arg 0]],
                 Arg 1,
                 App [Prim "env-get"; Arg 0])
      | _ -> assert false (* arity guaranteed by min/max_args *)) };
  { head = "glob"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$glob(pattern) — list a directory (records a tree: cell)";
    tmpl = (fun _ -> App [Prim "list-dir"; Arg 0]) };
  { head = "probe"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$probe(name) — read an observer-written volatile probe cell";
    tmpl = (fun _ -> App [Prim "probe"; Arg 0]) };
  { head = "secret"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$secret(path) — read a sealed (confidential) file";
    tmpl = (fun _ -> App [Prim "slurp"; Arg 0]) };
]

let find_head (name : string) : obs_head option =
  List.find_opt (fun h -> h.head = name) obs_heads

(* Error-message helper: the readers list the known heads from the table, so a
   typo report can never fall out of sync with what actually parses. *)
let known_heads_message () : string =
  "known observation heads: "
  ^ String.concat ", " (List.map (fun h -> "$" ^ h.head) obs_heads)

(* Arity check shared by both readers. Returns [Ok ()] or an [Error msg]. *)
let check_arity (h : obs_head) (n : int) : (unit, string) result =
  if n < h.min_args || n > h.max_args then
    let want =
      if h.min_args = h.max_args then string_of_int h.min_args
      else if h.max_args = max_int then Printf.sprintf "at least %d" h.min_args
      else Printf.sprintf "%d to %d" h.min_args h.max_args
    in
    Error (Printf.sprintf "$%s expects %s argument(s), got %d" h.head want n)
  else Ok ()

(* ---- with{} clauses --------------------------------------------------- *)

(* Each clause keyword maps to the wrapper constructor it lowers to. Kept as a
   variant (not a function) so the readers can pattern-match and the set stays
   greppable in exactly one place. *)
type with_wrapper = WCaps | WConfig | WHandlers

(* [colon] records the current (pre-B9) surface: caps/config take a `KEY: expr`
   clause; the handler clause is the two-token `handler NAME: fn` form and so is
   recognized by keyword alone here. B9 regularizes handlers to a `handlers:`
   map clause — at which point this row flips to colon=true and renames. *)
type with_clause = { clause : string; wrapper : with_wrapper; colon : bool; wdoc : string }

let with_clauses : with_clause list = [
  { clause = "caps";    wrapper = WCaps;    colon = true;
    wdoc = "caps: C — run the body with capability set C" };
  { clause = "config";  wrapper = WConfig;  colon = true;
    wdoc = "config: M — run the body with ambient config map M" };
  { clause = "handler"; wrapper = WHandlers; colon = false;
    wdoc = "handler NAME: fn — install one effect handler (B9 will move to \
            handlers: { :name -> fn, ... })" };
]

let find_with_clause (name : string) : with_clause option =
  List.find_opt (fun c -> c.clause = name) with_clauses

(* The "expected caps:, config:, or handler in with block" error text, built
   from the table so a new clause keyword can never be missing from the report. *)
let with_clauses_message () : string =
  let one c = if c.colon then c.clause ^ ":" else c.clause in
  "expected " ^ String.concat ", " (List.map one with_clauses) ^ " in with block"

(* ---- grant-descriptor sugar (needs fs.read(...) etc.) ----------------- *)

(* The dotted descriptors are sugar over `cap-restrict`; `needs` itself is
   value-open (any expression evaluating to a capability is accepted — see the
   lowering's passthrough and MASTER-PLAN A′3). This table is only the sugar. *)
type grant_sugar = { descriptor : string; restrict_mode : string; gdoc : string }

let grant_sugar : grant_sugar list = [
  { descriptor = "fs.read";  restrict_mode = "ro"; gdoc = "fs.read(p) — read-only fs grant for p" };
  { descriptor = "fs.write"; restrict_mode = "wo"; gdoc = "fs.write(p) — write-only fs grant for p" };
  { descriptor = "fs.rw";    restrict_mode = "rw"; gdoc = "fs.rw(p) — read-write fs grant for p" };
]

let find_grant_sugar (name : string) : grant_sugar option =
  List.find_opt (fun g -> g.descriptor = name) grant_sugar

(* ---- the exhaustive ratchet over Cell.t ------------------------------- *)

(* Every cell kind's surface story, decided in ONE place. The match is
   exhaustive; adding a [Cell.t] constructor without extending this function
   fails the build. A kind is either surfaced by a `$` head, recorded only as a
   side effect of running some primitive (no user-facing sigil), or read today
   through a plain named function pending a decision (lint whitelist). *)
type surface_story =
  | Surfaced of string          (* the obs_head [head] name that reads this kind *)
  | RuntimeRecorded of string   (* recorded by the runtime; no user surface *)
  | Whitelisted of string       (* read via a named function; no sigil (yet) *)

let surface_decision : Cell.t -> surface_story = function
  | Cell.File _        -> Surfaced "file"
  | Cell.Env _         -> Surfaced "env"
  | Cell.Tree _        -> Surfaced "glob"
  | Cell.Probe _       -> Surfaced "probe"
  | Cell.Sealed _      -> Surfaced "secret"
  | Cell.Stat _        -> Whitelisted "file predicates read via file-exists?/dir? \
                                       (no sigil; a future $stat is undecided)"
  | Cell.Config _      -> Whitelisted "config read via config(key); $config sugar lands in B5"
  | Cell.RuntimeFile _ -> RuntimeRecorded "loader read under interpreter authority (Q6)"
  | Cell.Tool _        -> RuntimeRecorded "the binary a run resolved to, recorded by run (D13)"
  | Cell.Argv          -> RuntimeRecorded "the program argument-list cell, read via argv"
  | Cell.Handler _     -> RuntimeRecorded "which handler intercepted an effect (LAW 26)"
  | Cell.Proc _        -> RuntimeRecorded "supervised-service state, recorded by the proc domain"
  | Cell.Domain _      -> RuntimeRecorded "a registered third-party domain's sub-cell (register-domain)"
  | Cell.Unknown _     -> RuntimeRecorded "unrecognized kind; can never re-verify"
