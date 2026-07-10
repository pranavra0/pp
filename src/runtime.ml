(* pp runtime — shared mutable state used by both backends *)

open Types

(* Handler stack for algebraic effects.
   Each entry is (effect-name, handler-fn, handler-value-hash). The third
   component (D17) lets a thunk's content-addressed key depend on the ambient
   handlers, since the handler-fn itself is an opaque OCaml closure. *)
let handler_stack : (string * (value list -> value) * string) list ref = ref []

(* Content hash of the current handler stack (for thunk keys). *)
let handlers_hash () =
  hash_concat
    ("handlers"
     :: List.concat_map (fun (n, _, h) -> [n; h]) !handler_stack)

(* Current capability set (for effectful blocks) *)
let current_capabilities : capability list ref = ref []

(* ReaderT-style ambient config stack *)
let config_stack : value list ref = ref []

(* Content-addressed thunk store *)
let thunk_store : (string, thunk) Hashtbl.t = Hashtbl.create 1024

(* ---- Trace recording: the verifying-trace cache-validity mechanism ----

   A node's persistent-store key covers only its *identity* (code + argument
   value hashes) — never what it *read* from the world. That split is why a
   "pure-enough" heuristic can't make the cache sound: pp is dynamically typed
   by choice (SPEC §0), so there is no static IO type to consult, and a node's
   reads are discovered only by running it. The trace is pp's dynamic answer to
   Haskell's static IO type: instead of a type that says "this MAY touch the
   world," a trace records what the node actually DID touch — each read as a
   (cell-id, observed-hash) pair — and a cache hit re-verifies every pair
   against the current world before serving the stored result (SPEC LAW 21,
   DESIGN Q2/Q8).

   Each node force pushes a fresh frame; every world-read during its evaluation
   is recorded into *all* active frames, so a parent's trace transitively
   subsumes the reads of nested (non-node) computation it forced. *)
let trace_stack : (string * string) list ref list ref = ref []

(* Program-level observation collection for the reconciler's stratification
   check (LAW 30): when enabled (pp --reconcile), every recorded cell
   observation — whether or not a node frame is active — is also appended
   here, so the reconciler can refuse a desired state whose computation read
   its own domain. *)
let observe_all = ref false
let observed_all : (string * string) list ref = ref []

(* Record a (cell-id, observed-hash) world-read into every active trace frame.
   Deduplicated per frame on the (cell, hash) PAIR — not the cell alone: if one
   run observes the same cell with two different hashes (a file changed mid-run,
   a config key read under two scopes), both observations are kept, and a trace
   containing both can never verify — forcing a recompute, which is the only
   sound answer for a run that saw an inconsistent world. *)
let record_read (cell_id : string) (observed_hash : string) : unit =
  List.iter (fun frame ->
    if not (List.mem (cell_id, observed_hash) !frame) then
      frame := (cell_id, observed_hash) :: !frame)
    !trace_stack;
  if !observe_all then observed_all := (cell_id, observed_hash) :: !observed_all

(* ---- Per-node sandbox (LAW 18, DESIGN Q2 sandbox v1) ----

   One slot per active node force, parallel to trace_stack. The directory is
   created lazily on the first `run` or scratch write inside the node and
   removed when the node's frame pops (every exit path). Scratch is node-local
   working memory: reads/writes inside it are neither capability-checked nor
   recorded in the trace — only values that the node returns escape. *)
let sandbox_stack : string option ref list ref = ref []
let sandbox_counter = ref 0

let rec remove_tree (path : string) : unit =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove_tree (Filename.concat path name))
        (Sys.readdir path);
      (try Unix.rmdir path with _ -> ())
  | _ -> (try Sys.remove path with _ -> ())
  | exception _ -> ()

(* Innermost node's sandbox; created on demand when [create] is set. *)
let current_sandbox ~(create : bool) : string option =
  match !sandbox_stack with
  | [] -> None
  | slot :: _ ->
      (match !slot with
       | Some d -> Some d
       | None ->
           if create then begin
             incr sandbox_counter;
             let d = Filename.concat (Filename.get_temp_dir_name ())
                 (Printf.sprintf "pp-sandbox-%d-%d"
                    (Unix.getpid ()) !sandbox_counter) in
             (try Unix.mkdir d 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
             slot := Some d;
             Some d
           end else None)

(* A relative path inside a node resolves into the node's sandbox (creating
   it if [create]); absolute paths and scripting-tier paths resolve to None
   and take the ordinary capability-checked route. *)
let sandbox_resolve ?(create = false) (path : string) : string option =
  if Filename.is_relative path && !sandbox_stack <> [] then
    match current_sandbox ~create with
    | Some d -> Some (Filename.concat d path)
    | None -> None
  else None

let push_trace_frame () : (string * string) list ref =
  let frame = ref [] in
  trace_stack := frame :: !trace_stack;
  sandbox_stack := ref None :: !sandbox_stack;
  frame

let pop_trace_frame () : unit =
  (match !sandbox_stack with
   | slot :: rest ->
       (match !slot with Some d -> remove_tree d | None -> ());
       sandbox_stack := rest
   | [] -> ());
  match !trace_stack with
  | _ :: rest -> trace_stack := rest
  | [] -> ()

(* ---- LAW 33 / LAW 26: config and handlers are observations, not identity ----

   The persistent node key covers code + free-var value hashes only (LAW 20).
   A node that reads `(config k)` or performs an effect has OBSERVED ambient
   state, so the read is recorded as a trace cell — `config:<key>` /
   `handler:<effect>` — and re-observed at hit time against the caller's
   current config/handler stacks, exactly like a file cell is re-observed
   against the current file contents. These helpers are the single code path
   for both the record (during a node run) and the re-observation (during a
   hit check), so the two can never disagree. *)

(* Set by Evaluator at startup: config values may be unforced thunks; their
   observed hash is the hash of the forced value. *)
let force_hook : (value -> value) ref = ref (fun v -> v)

let config_cell_id (key : string) : string = "config:" ^ key
let handler_cell_id (name : string) : string = "handler:" ^ name

(* Observed hash for a config key with no binding: absence is a real,
   re-observable observation (providing the key later must invalidate). *)
let config_absent_hash = hash_string "config-cell:absent"
(* Observed hash for an effect that fell through to the builtin handler:
   installing a semantic handler later must invalidate (LAW 26). *)
let builtin_handler_hash = hash_string "handler-cell:builtin"

(* Innermost binding for [key] in the ambient config stack (both backends'
   lookup rule: VString entry first, then VKeyword, outward per frame). *)
let config_lookup (key : string) : value option =
  let rec find = function
    | [] -> None
    | VMap kvs :: rest ->
        (match List.assoc_opt (VString key) kvs with
         | Some v -> Some v
         | None ->
             (match List.assoc_opt (VKeyword key) kvs with
              | Some v -> Some v
              | None -> find rest))
    | _ :: rest -> find rest
  in
  find !config_stack

let observe_config (key : string) : string =
  match config_lookup key with
  | Some v -> hash_value (!force_hook v)
  | None -> config_absent_hash

let observe_handler (name : string) : string =
  let rec find = function
    | [] -> builtin_handler_hash
    | (n, _, h) :: rest -> if n = name then h else find rest
  in
  find !handler_stack

(* Record-side entry points; no-ops outside a node (no active trace frame). *)
let record_config_read (key : string) : unit =
  if !trace_stack <> [] then
    record_read (config_cell_id key) (observe_config key)

let record_handler_observation (name : string) : unit =
  if !trace_stack <> [] then
    record_read (handler_cell_id name) (observe_handler name)

(* ---- Loader authority — the runtime/traced split (DESIGN Q6, D8c) ----

   `load`/`load-module`/`island` run with the INTERPRETER's authority, not the
   user capability set: they are the loader, not user effects. That authority
   is bounded — the directories of the CLI-named programs, the working
   directory, and ~/.pp — so the loader is no longer an unbounded ambient
   read hole. Each loader read is recorded as a `runtime:file:` trace cell:
   it participates in cache VALIDITY (editing a loaded file invalidates the
   nodes that loaded it) but is excluded from the caller's hit-time authority
   requirement (cell_authorized passes runtime: cells unconditionally). *)

let source_roots : string list ref = ref []

(* Lexical normalization (cwd-anchor, ".."/"." collapse) — no realpath, per
   the store's uniform-canonicalization caveat; the bound is a policy fence,
   not a security boundary against symlinks (Phase 1). *)
let normalize_path (p : string) : string =
  let p = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p in
  let rec go acc = function
    | [] -> List.rev acc
    | ("" | ".") :: rest -> go acc rest
    | ".." :: rest -> (match acc with _ :: t -> go t rest | [] -> go [] rest)
    | x :: rest -> go (x :: acc) rest
  in
  "/" ^ String.concat "/" (go [] (String.split_on_char '/' p))

let path_under ~(root : string) (path : string) : bool =
  path = root
  || (String.length path > String.length root
      && String.sub path 0 (String.length root) = root
      && (root = "/" || path.[String.length root] = '/'))

let loader_authorized (path : string) : bool =
  let p = normalize_path path in
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let roots = Filename.concat home ".pp" :: !source_roots in
  List.exists (fun r -> path_under ~root:(normalize_path r) p) roots

let loader_read (path : string) : string =
  if not (loader_authorized path) then
    failwith ("load: " ^ path
              ^ " is outside the interpreter's source roots (loader authority \
                 is bounded — DESIGN Q6/D8c)");
  let ic = open_in path in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  record_read ("runtime:file:" ^ path) (hash_string content);
  content

(* Initial capabilities from --grant (set by main.ml before init) *)
let initial_capabilities : capability list ref = ref []

(* Program arguments: everything after `--` on the pp command line (set by
   main.ml). Read by the `argv` primitive, which records an `argv:` trace
   cell so a node that observed them recomputes when they change. *)
let program_argv : string list ref = ref []
