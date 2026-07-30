open Pp_kernel
(* surface_tables — the closed surface sets as data.

   The recurring defect class on this branch was the same closed list written
   out by hand in N places — the `$` observation heads in the normal reader and
   again in the quasiquote reader, the grant-descriptor sugar, the `with`-clause
   keywords, the lint whitelists, the fuzzer's generators, and SPEC. Every one
   of those hand-maintained copies drifts. This module is the fix: each closed
   set is ONE typed value here, and every other layer derives from it.

   Three tables live here:

   1. [obs_heads]      — the `$KIND(...)` observation sigils. Both readers
                         (normal and `quasiquote{}`) parse a head's arguments as
                         an ordinary expression list (computed paths, not
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

type arity = {
  min : int;
  max : int;
}

type obs_head = {
  kind : Core_model.observation_kind;
  head : string;
  arity : arity;
  doc : string;
}

let exact n = { min = n; max = n }
let optional_second = { min = 1; max = 2 }

let obs_heads : obs_head list = [
  { kind = File; head = "file"; arity = exact 1;
    doc = "read file contents, sealed when only secret authority covers the path" };
  { kind = Env; head = "env"; arity = optional_second;
    doc = "read an environment variable, optionally defaulting when absent" };
  { kind = Tree; head = "tree"; arity = exact 1;
    doc = "read a directory tree as relative paths mapped to content hashes" };
  { kind = Probe; head = "probe"; arity = exact 1;
    doc = "read an observer-written volatile probe cell" };
  { kind = Secret; head = "secret"; arity = exact 1;
    doc = "read confidential bytes as a sealed value" };
  { kind = Stat; head = "stat"; arity = exact 1;
    doc = "read a path kind as :file, :directory, or nil" };
  { kind = Argv; head = "argv"; arity = exact 0;
    doc = "read the invocation argument list" };
  { kind = Config; head = "config"; arity = optional_second;
    doc = "read scoped configuration, optionally defaulting when absent" };
]

let find_head name =
  List.find_opt (fun observation -> observation.head = name) obs_heads

let find_kind kind =
  List.find_opt (fun observation -> observation.kind = kind) obs_heads

let known_heads_message () =
  "known observation heads: "
  ^ String.concat ", " (List.map (fun observation -> "$" ^ observation.head) obs_heads)

let check_arity observation count =
  if count < observation.arity.min || count > observation.arity.max then
    let expected =
      if observation.arity.min = observation.arity.max then
        string_of_int observation.arity.min
      else
        Printf.sprintf "%d to %d" observation.arity.min observation.arity.max
    in
    Error
      (Printf.sprintf "$%s expects %s argument(s), got %d"
         observation.head expected count)
  else
    Ok ()

(* ---- with{} clauses --------------------------------------------------- *)

(* Each clause keyword maps to the wrapper constructor it lowers to. Kept as a
   variant (not a function) so the readers can pattern-match and the set stays
   greppable in exactly one place. *)
type with_wrapper = WCaps | WConfig | WHandlers

(* Every clause is a `KEY: value` clause ([colon] = true for all three).
   `handlers:` takes a map literal `{ :name -> fn, ... }` — the reader
   extracts its `:name -> fn` pairs into the handler install (the regularized
   form replacing the old two-token `handler NAME: fn` key). *)
type with_clause = { clause : string; wrapper : with_wrapper; colon : bool; wdoc : string }

let with_clauses : with_clause list = [
  { clause = "caps";     wrapper = WCaps;     colon = true;
    wdoc = "caps: C — run the body with capability set C" };
  { clause = "config";   wrapper = WConfig;   colon = true;
    wdoc = "config: M — run the body with ambient config map M" };
  { clause = "handlers"; wrapper = WHandlers; colon = true;
    wdoc = "handlers: { :name -> fn, ... } — install a map of effect handlers" };
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
   lowering's passthrough; a named or composed grant, e.g.
   `let k8s-prod = cap-compose(net("k8s.prod.internal"), process)`, works
   identically). This table is only the sugar. *)
type grant_sugar = { descriptor : string; restrict_mode : string; gdoc : string }

let grant_sugar : grant_sugar list = [
  { descriptor = "fs.read";  restrict_mode = "ro"; gdoc = "fs.read(p) — read-only fs grant for p" };
  { descriptor = "fs.write"; restrict_mode = "wo"; gdoc = "fs.write(p) — write-only fs grant for p" };
  { descriptor = "fs.rw";    restrict_mode = "rw"; gdoc = "fs.rw(p) — read-write fs grant for p" };
]

let find_grant_sugar (name : string) : grant_sugar option =
  List.find_opt (fun g -> g.descriptor = name) grant_sugar


(* ---- SPEC rendering ---------------------------------------------------- *)

(* The tables above are the ONLY hand-authored copy of these closed sets. SPEC
   used to hand-list them in prose, which went stale as the tables changed;
   instead it now carries
   a *generated* block regenerated from here and diffed against the committed
   copy. A table
   edit that isn't mirrored into SPEC is therefore a red build, not a stale
   paragraph — the doc-sync failure mode becomes mechanical. This function emits
   exactly the text that lives between SPEC's generated-block markers. *)

let render_arity observation =
  if observation.arity.min = observation.arity.max then
    string_of_int observation.arity.min
  else
    Printf.sprintf "%d..%d" observation.arity.min observation.arity.max

let render_observe observation =
  let arguments =
    List.init observation.arity.max (fun index ->
      Printf.sprintf "$%d" (index + 1))
  in
  String.concat " "
    ("(observe" :: Core_model.string_of_observation_kind observation.kind
     :: arguments)
  ^ ")"

let render_wrapper : with_wrapper -> string = function
  | WCaps -> "with-caps"
  | WConfig -> "with-config"
  | WHandlers -> "with-handler"

let render_spec_tables () : string =
  let b = Buffer.create 2048 in
  let line s = Buffer.add_string b s; Buffer.add_char b '\n' in
  line "#### Observation heads — `$KIND(args…)`";
  line "";
  line "| head | arity | AST | meaning |";
  line "|---|---|---|---|";
  List.iter (fun observation ->
    line
      (Printf.sprintf "| `$%s` | %s | `%s` | %s |"
         observation.head (render_arity observation)
         (render_observe observation) observation.doc))
    obs_heads;
  line "";
  line "#### `with { }` clauses";
  line "";
  line "| keyword | wrapper | meaning |";
  line "|---|---|---|";
  List.iter (fun c ->
    let kw = if c.colon then c.clause ^ ":" else c.clause ^ " NAME:" in
    line (Printf.sprintf "| `%s` | `%s` | %s |"
            kw (render_wrapper c.wrapper) c.wdoc))
    with_clauses;
  line "";
  line "#### Grant-descriptor sugar (inside `needs`)";
  line "";
  line "| descriptor | lowering | meaning |";
  line "|---|---|---|";
  List.iter (fun g ->
    line (Printf.sprintf "| `%s` | `(cap-restrict (current-capabilities) $1 :%s)` | %s |"
            g.descriptor g.restrict_mode g.gdoc))
    grant_sugar;
  Buffer.contents b

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
  | Cell.File _ -> Surfaced "file"
  | Cell.Env _ -> Surfaced "env"
  | Cell.Tree _ -> Surfaced "tree"
  | Cell.Probe _ -> Surfaced "probe"
  | Cell.Sealed _ -> Surfaced "secret"
  | Cell.Stat _ -> Surfaced "stat"
  | Cell.Config _ -> Surfaced "config"
  | Cell.RuntimeFile _ -> RuntimeRecorded "loader read under interpreter authority (Q6)"
  | Cell.Tool _        -> RuntimeRecorded "the binary a run resolved to, recorded by run (D13)"
  | Cell.Argv -> Surfaced "argv"
  | Cell.Handler _     -> RuntimeRecorded "which handler intercepted an effect"
  | Cell.Node _        -> RuntimeRecorded "a persistent child node's result hash"
  | Cell.Domain _      -> RuntimeRecorded "a registered third-party domain's sub-cell (register-domain!)"
  | Cell.Unknown _     -> RuntimeRecorded "unrecognized kind; can never re-verify"
