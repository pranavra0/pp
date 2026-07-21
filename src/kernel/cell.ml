(* pp cells — the typed taxonomy of world observations.

   A cell is one observable unit of the world a node can read; a trace records
   (cell, observed-hash) pairs and a hit re-observes them. Cells
   are persisted as quoted strings inside trace lines (Trace_repository's canonical
   text format), so [serialize]/[parse] round-trip EXACTLY — the
   on-disk format is frozen; this module only replaces scattered
   "file:" ^ path concatenations and prefix-sniffing cascades with one
   constructor/parser pair.

   Observation owns re-observation and authorization; this module owns naming.

   File-cell paths are canonicalized before they ever reach [serialize]
   (World_path.canonical: absolute realpath,
   no trailing slash), so a canonical path always starts with '/'. That
   invariant RESERVES the grammar for a future host-qualified form,
   "file:<host>:<canonical-path>": the character right after
   "file:" unambiguously distinguishes them — '/' means a local canonical
   path, anything else is a host token — so parsing never has to special-case
   today's local-only cells to make room for it. No host cell is implemented
   here; this is the reservation only. *)

type t =
  | File of string         (* file contents, by canonical path *)
  | RuntimeFile of string  (* a loader read: interpreter authority, not the user's *)
  | Tool of string         (* the command binary a `run` resolved to *)
  | Tree of string         (* whole-tree content hash — the coarse soundness floor *)
  | Stat of string         (* file predicate: presence/kind, never contents *)
  | Env of string          (* environment variable, absence included *)
  | Argv                   (* the single program-argument-list cell *)
  | Config of string       (* ambient config key observation *)
  | Handler of string      (* which handler intercepted an effect *)
  | Probe of string        (* observer-written volatile cell, "probe:<name>" —
                               driver-evaluated at most once per pass, capability-
                               free at the read site (authority was consumed by
                               the probe's own evaluation, under its registered
                               read-cap) *)
  | Sealed of string       (* sealed (confidential) read, "sealed:<canonical-
                               path>" — hash of the secret bytes only; the bytes
                               themselves never enter the CAS (session-only pins,
                               in-memory-only) *)
  | Node of string         (* child node key, observed as its current result hash *)
  | Domain of { name : string; sub : string }
                           (* registered domain sub-cell; [sub] is opaque *)
  | Unknown of string      (* unrecognized kind: can never re-verify *)

let serialize = function
  | File path -> "file:" ^ path
  | RuntimeFile path -> "runtime:file:" ^ path
  | Tool path -> "tool:" ^ path
  | Tree root -> "tree:" ^ root
  | Stat path -> "stat:" ^ path
  | Env name -> "env:" ^ name
  | Argv -> "argv:"
  | Config key -> "config:" ^ key
  | Handler name -> "handler:" ^ name
  | Probe name -> "probe:" ^ name
  | Sealed path -> "sealed:" ^ path
  | Node key -> "node:" ^ key
  | Domain { name; sub } -> "domain:" ^ name ^ ":" ^ sub
  | Unknown s -> s

(* The string-payload cell kinds: prefix + how to rebuild the constructor from
   the stripped payload. Most-specific prefix first ([parse] tries them in
   order, so "runtime:file:" must precede "file:"). [parse] derives from this
   one table; [serialize] stays the explicit exhaustive match above (the compiler
   forces a printed form for a new constructor); the round-trip ratchet below
   ties the two so a kind added to one direction but not the other fails. Argv
   (no payload) and Domain (two fields) are structurally special, handled
   explicitly in both directions. *)
let string_kinds : (string * (string -> t)) list = [
  "runtime:file:", (fun p -> RuntimeFile p);
  "file:",         (fun p -> File p);
  "tool:",         (fun p -> Tool p);
  "tree:",         (fun p -> Tree p);
  "stat:",         (fun p -> Stat p);
  "env:",          (fun p -> Env p);
  "config:",       (fun p -> Config p);
  "handler:",      (fun p -> Handler p);
  "probe:",        (fun p -> Probe p);
  "sealed:",       (fun p -> Sealed p);
  "node:",         (fun key -> Node key);
]

let parse (s : string) : t =
  let has prefix =
    let plen = String.length prefix in
    String.length s >= plen && String.sub s 0 plen = prefix
  in
  let strip prefix =
    String.sub s (String.length prefix) (String.length s - String.length prefix)
  in
  let rec try_kinds = function
    | (prefix, mk) :: rest -> if has prefix then mk (strip prefix) else try_kinds rest
    | [] ->
        if has "domain:" then
          let rest = strip "domain:" in
          (match String.index_opt rest ':' with
           | Some i ->
               Domain { name = String.sub rest 0 i;
                        sub = String.sub rest (i + 1) (String.length rest - i - 1) }
           | None -> Domain { name = rest; sub = "" })
        else if s = "argv:" then Argv
        else Unknown s
  in
  try_kinds string_kinds

(* Round-trip ratchet: a new constructor makes the [_cover] match non-exhaustive
   (a build error, which the comment sends here), and the assertion fails the
   build if serialize/parse disagree for any representative. *)
let () =
  let _cover : t -> unit = function
    | File _ | RuntimeFile _ | Tool _ | Tree _ | Stat _ | Env _ | Argv
    | Config _ | Handler _ | Probe _ | Sealed _ | Node _ | Domain _
    | Unknown _ -> ()
  in
  List.iter (fun t -> assert (parse (serialize t) = t))
    [ File "/x"; RuntimeFile "/x"; Tool "/x"; Tree "/x"; Stat "/x"; Env "X";
      Argv; Config "k"; Handler "h"; Probe "p"; Sealed "/x"; Node "abc";
      Domain { name = "d"; sub = "s" }; Domain { name = "d"; sub = "" };
      Unknown "zzz:unrecognized" ]
