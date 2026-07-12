(* pp cells — the typed taxonomy of world observations.

   A cell is one observable unit of the world a node can read; a trace records
   (cell, observed-hash) pairs and a hit re-observes them (SPEC LAW 21). Cells
   are persisted as quoted strings inside trace lines (store.ml's canonical
   text format, M2.2), so [to_string]/[of_string] round-trip EXACTLY — the
   on-disk format is frozen; this module only replaces scattered
   "file:" ^ path concatenations and prefix-sniffing cascades with one
   constructor/parser pair.

   Who re-observes and who may read each kind is decided elsewhere
   (Store.observe_cell / Evaluator.cell_authorized); this module owns only the
   naming.

   File-cell paths are canonicalized before they ever reach [to_string]
   (Runtime.canonical_path — SPEC LAW 23 / DESIGN §2.1: absolute realpath,
   no trailing slash), so a canonical path always starts with '/'. That
   invariant RESERVES the grammar for a future host-qualified form,
   "file:<host>:<canonical-path>" (M2/MASTERPLAN): the character right after
   "file:" unambiguously distinguishes them — '/' means a local canonical
   path, anything else is a host token — so parsing never has to special-case
   today's local-only cells to make room for it. No host cell is implemented
   here; this is the reservation only. *)

type t =
  | File of string         (* file contents, by canonical path (LAW 23) *)
  | RuntimeFile of string  (* a loader read (Q6): interpreter authority, not the user's *)
  | Tool of string         (* the command binary a `run` resolved to (D13) *)
  | Tree of string         (* whole-tree content hash — Q2's coarse soundness floor *)
  | Stat of string         (* file predicate: presence/kind, never contents *)
  | Env of string          (* environment variable, absence included *)
  | Argv                   (* the single program-argument-list cell *)
  | Config of string       (* ambient config key observation (LAW 33) *)
  | Handler of string      (* which handler intercepted an effect (LAW 26) *)
  | Proc of string         (* supervised service: running spec hash or stopped *)
  | Unknown of string      (* unrecognized kind: can never re-verify *)

let to_string = function
  | File path -> "file:" ^ path
  | RuntimeFile path -> "runtime:file:" ^ path
  | Tool path -> "tool:" ^ path
  | Tree root -> "tree:" ^ root
  | Stat path -> "stat:" ^ path
  | Env name -> "env:" ^ name
  | Argv -> "argv:"
  | Config key -> "config:" ^ key
  | Handler name -> "handler:" ^ name
  | Proc name -> "proc:" ^ name
  | Unknown s -> s

let of_string (s : string) : t =
  let strip prefix =
    let plen = String.length prefix in
    if String.length s >= plen && String.sub s 0 plen = prefix then
      Some (String.sub s plen (String.length s - plen))
    else None
  in
  (* "runtime:file:" before "file:" is not needed (distinct prefixes), but
     keep the more specific kinds first for readability. *)
  match strip "runtime:file:" with Some p -> RuntimeFile p | None ->
  match strip "file:" with Some p -> File p | None ->
  match strip "tool:" with Some p -> Tool p | None ->
  match strip "tree:" with Some r -> Tree r | None ->
  match strip "stat:" with Some p -> Stat p | None ->
  match strip "env:" with Some n -> Env n | None ->
  match strip "config:" with Some k -> Config k | None ->
  match strip "handler:" with Some n -> Handler n | None ->
  match strip "proc:" with Some n -> Proc n | None ->
  if s = "argv:" then Argv else Unknown s
