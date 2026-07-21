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

(* A head's lowering is a small template, not an OCaml closure — because it must
   be produced in TWO shapes: real AST nodes in the normal reader, and quoted
   list-building data in the quasiquote reader — `$`-head parity between the
   two readers lives in this one shape rather than two hand-kept copies.
   Both readers walk the
   same [tmpl] with their own interpreter, so a head added here exists in both
   with the SAME lowering by construction — no second copy to drift. *)
type tmpl =
  | Prim of string          (* a primitive symbol, e.g. "slurp" *)
  | Arg of int              (* the i-th user-supplied argument (0-based) *)
  | App of tmpl list        (* application: head then args *)
  | If of tmpl * tmpl * tmpl
  | Perform of string * tmpl list
    (* (perform EFFECT args…) — an observation that must route through an
       effect, not a plain call: $glob records a `tree:` cell via the
       [tree-observe] effect (the same lowering the `tree:` literal uses), which
       a bare application to a primitive symbol cannot express. *)
  | Config of tmpl * tmpl option
    (* (config KEY [DEFAULT]) — a scoped config read (records a `config:` cell).
       $config lowers to the EConfig AST node, not a plain call: the read
       is a distinct special form, like [Perform]. *)

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
    doc = "$glob(path) — observe a directory tree (records a tree: cell)";
    tmpl = (fun _ -> Perform ("tree-observe", [Arg 0])) };
  { head = "probe"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$probe(name) — read an observer-written volatile probe cell";
    tmpl = (fun _ -> App [Prim "probe"; Arg 0]) };
  { head = "secret"; min_args = 1; max_args = 1; qq_legal = true;
    doc = "$secret(path) — read a sealed (confidential) file";
    tmpl = (fun _ -> App [Prim "slurp"; Arg 0]) };
  { head = "config"; min_args = 1; max_args = 2; qq_legal = true;
    doc = "$config(key[, default]) — read a scoped config value (records a \
           config: cell); the optional default is used when the key is unset";
    tmpl = (fun n -> match n with
      | 1 -> Config (Arg 0, None)
      | 2 -> Config (Arg 0, Some (Arg 1))
      | _ -> assert false (* arity guaranteed by min/max_args *)) };
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

(* Coverage ratchet: every head's [tmpl] must be defined for every arity it
   declares, so widening [max_args] without adding a template arm fails here
   (module load) instead of at an [assert false] deep in some later lowering.
   Variadic heads (max_args = max_int) must be total in their arity, so a small
   window past min_args suffices to exercise the wildcard arm. *)
let () =
  List.iter (fun h ->
    let hi = if h.max_args = max_int then h.min_args + 2 else h.max_args in
    for n = h.min_args to hi do
      match (try Some (h.tmpl n) with Match_failure _ -> None) with
      | Some _ -> ()
      | None ->
          failwith (Printf.sprintf
            "surface_tables: $%s declares arity %d..%s but its template has no \
             arm for %d" h.head h.min_args
            (if h.max_args = max_int then "variadic" else string_of_int h.max_args)
            n)
    done)
    obs_heads

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

(* ---- observation-exclusivity primitives ------------------------------- *)

(* The bare world-read primitives the `$` family wraps, each paired with the
   `$` head that should be used instead. `pp lint`'s observation-exclusivity
   check flags a bare use of one of these outside `stdlib/`, pointing at
   its head. One list, next to [obs_heads], so the lint set can never drift
   from the family. `tree-observe` is a perform effect (behind `$glob`); the
   rest are plain primitives. Note the family's own tmpl helpers (e.g. `nil?`
   in `$env`'s lowering) are NOT reads and are deliberately absent. *)
let observation_primitives : (string * string) list =
  [ "slurp",        "$file (or $secret for a sealed read)";
    "env-get",      "$env";
    "probe",        "$probe";
    "config",       "$config";
    "tree-observe", "$glob" ]

let observation_primitive (name : string) : string option =
  List.assoc_opt name observation_primitives

(* ---- SPEC rendering ---------------------------------------------------- *)

(* The tables above are the ONLY hand-authored copy of these closed sets. SPEC
   used to hand-list them in prose, which went stale as the tables changed;
   instead it now carries
   a *generated* block regenerated from here and diffed against the committed
   copy. A table
   edit that isn't mirrored into SPEC is therefore a red build, not a stale
   paragraph — the doc-sync failure mode becomes mechanical. This function emits
   exactly the text that lives between SPEC's generated-block markers. *)

(* Render a lowering template back to its s-expression spelling; user arguments
   show as positional holes [$1], [$2], … (1-based) so the shape is legible
   without inventing parameter names. *)
let rec render_tmpl : tmpl -> string = function
  | Prim s -> s
  | Arg i -> Printf.sprintf "$%d" (i + 1)
  | App ts -> "(" ^ String.concat " " (List.map render_tmpl ts) ^ ")"
  | If (c, t, e) ->
      Printf.sprintf "(if %s %s %s)"
        (render_tmpl c) (render_tmpl t) (render_tmpl e)
  | Perform (eff, ts) ->
      "(perform " ^ eff ^ " " ^ String.concat " " (List.map render_tmpl ts) ^ ")"
  | Config (k, d) ->
      (match d with
       | Some d -> Printf.sprintf "(config %s %s)" (render_tmpl k) (render_tmpl d)
       | None -> Printf.sprintf "(config %s)" (render_tmpl k))

let render_arity (h : obs_head) : string =
  if h.min_args = h.max_args then string_of_int h.min_args
  else if h.max_args = max_int then Printf.sprintf "%d+" h.min_args
  else Printf.sprintf "%d..%d" h.min_args h.max_args

let render_wrapper : with_wrapper -> string = function
  | WCaps -> "with-caps"
  | WConfig -> "with-config"
  | WHandlers -> "with-handler"

let render_spec_tables () : string =
  let b = Buffer.create 2048 in
  let line s = Buffer.add_string b s; Buffer.add_char b '\n' in
  line "#### Observation heads — `$KIND(args…)`";
  line "";
  line "| head | arity | qq | lowering | meaning |";
  line "|---|---|---|---|---|";
  List.iter (fun h ->
    (* the max-arity template is the most informative shape (e.g. $env's
       with-default form); arity is pre-checked before the reader interprets it *)
    let arity_for_tmpl = if h.max_args = max_int then h.min_args else h.max_args in
    line (Printf.sprintf "| `$%s` | %s | %s | `%s` | %s |"
            h.head (render_arity h)
            (if h.qq_legal then "yes" else "no")
            (render_tmpl (h.tmpl arity_for_tmpl))
            h.doc))
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
  | Cell.File _        -> Surfaced "file"
  | Cell.Env _         -> Surfaced "env"
  | Cell.Tree _        -> Surfaced "glob"
  | Cell.Probe _       -> Surfaced "probe"
  | Cell.Sealed _      -> Surfaced "secret"
  | Cell.Stat _        -> Whitelisted "file predicates read via file-exists?/dir? \
                                       (no sigil; a future $stat is undecided)"
  | Cell.Config _      -> Surfaced "config"
  | Cell.RuntimeFile _ -> RuntimeRecorded "loader read under interpreter authority (Q6)"
  | Cell.Tool _        -> RuntimeRecorded "the binary a run resolved to, recorded by run (D13)"
  | Cell.Argv          -> RuntimeRecorded "the program argument-list cell, read via argv"
  | Cell.Handler _     -> RuntimeRecorded "which handler intercepted an effect"
  | Cell.Node _        -> RuntimeRecorded "a persistent child node's result hash"
  | Cell.Domain _      -> RuntimeRecorded "a registered third-party domain's sub-cell (register-domain)"
  | Cell.Unknown _     -> RuntimeRecorded "unrecognized kind; can never re-verify"
