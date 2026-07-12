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

(* Dynamic scoping: set [r] to [v] for the extent of [f], restoring the saved
   value on normal return AND on exception. The shape behind effect blocks,
   handler installation, and config scoping. *)
let with_ref (r : 'a ref) (v : 'a) (f : unit -> 'b) : 'b =
  let saved = !r in
  r := v;
  match f () with
  | result -> r := saved; result
  | exception e -> r := saved; raise e

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

(* Process-domain reconciler cell observation hook. Set by Supervisor.init
   so that Store.observe_cell can re-observe proc:<name> cells. *)
let proc_observer : (string -> string option) ref = ref (fun _ -> None)

let observe_proc (name : string) : string option =
  !proc_observer name

let config_cell_id (key : string) : string = Cell.(to_string (Config key))
let handler_cell_id (name : string) : string = Cell.(to_string (Handler name))

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

(* SPEC LAW 23 / DESIGN §2.1: the ONE cell-id canonicalization function,
   applied at every file:/tree:/stat:/tool:/runtime:file: construction site,
   every --grant path, and the loader bound — so two syntactically different
   paths naming the same inode collapse to one cell (the D8 path-prefix bug
   class, now closed at the cell layer: macOS /var vs /private/var, a
   symlinked source tree, and a trailing slash all name the same cell).

   Existing paths: made absolute, then realpath (symlinks resolved). Paths
   that do not (yet) exist — a write-target before its file is created —
   realpath the longest EXISTING prefix and append the remaining components
   lexically normalized ("." dropped, ".." pops the previous remaining
   component); this is why a write-target's cell id is stable across the
   file's creation (tests/036). No trailing slash (root "/" excepted).

   NFC Unicode normalization is NOT implemented — a documented residual
   (SPEC LAW 23, STATUS.md); it would need a new dependency (uunf, DESIGN
   E6) and is orthogonal to the realpath fix this closes. *)
let canonical_path (p : string) : string =
  let abs = if Filename.is_relative p then Filename.concat (Sys.getcwd ()) p else p in
  let strip_trailing s =
    let n = String.length s in
    if n > 1 && s.[n - 1] = '/' then String.sub s 0 (n - 1) else s
  in
  let abs = strip_trailing abs in
  let parts = List.filter (fun s -> s <> "") (String.split_on_char '/' abs) in
  let rec split_existing n =
    if n = 0 then ("/", parts)
    else
      let prefix_parts = List.filteri (fun i _ -> i < n) parts in
      let candidate = "/" ^ String.concat "/" prefix_parts in
      if Sys.file_exists candidate then
        (candidate, List.filteri (fun i _ -> i >= n) parts)
      else split_existing (n - 1)
  in
  let (existing, remaining) = split_existing (List.length parts) in
  let real_existing = try Unix.realpath existing with _ -> existing in
  (* Lexically normalize the nonexistent tail only; the existing prefix was
     already resolved by realpath above. *)
  let normalized_tail =
    List.rev
      (List.fold_left (fun acc part ->
         match part with
         | "." -> acc
         | ".." -> (match acc with _ :: t -> t | [] -> acc)
         | x -> x :: acc)
         [] remaining)
  in
  match normalized_tail with
  | [] -> real_existing
  | _ -> real_existing ^ "/" ^ String.concat "/" normalized_tail

let loader_authorized (path : string) : bool =
  let p = canonical_path path in
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let roots = canonical_path (Filename.concat home ".pp") :: !source_roots in
  List.exists (fun r -> Paths.under ~root:r p) roots

let loader_read (path : string) : string =
  let canon = canonical_path path in
  if not (loader_authorized path) then
    failwith ("load: " ^ path
              ^ " is outside the interpreter's source roots (loader authority \
                 is bounded — DESIGN Q6/D8c)");
  let ic = open_in canon in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  record_read (Cell.(to_string (RuntimeFile canon))) (hash_string content);
  content

(* ---- LAW 29 / D12: source locations on runtime errors, never doubled ----

   A runtime error escaping a form's evaluation should report THAT form's
   own file:line — unless its message already carries one (a trailing
   " at <file>:<line>"), in which case it is left alone: a deeper, more
   specific location already won and must not be overwritten by an outer,
   less specific one.

   One implementation, shared by every driver that evaluates a sequence of
   located top-level-shaped forms: the top-level driver (repl.ml,
   execute_file/execute_file_bytecode, both backends), the tree-walker's
   `load` (evaluator.ml eval_expressions), and the VM's LOAD_FILE opcode
   (vm.ml). Applying it at `load` granularity too (not just the outermost
   top level) is what closes the D12 residual: an error inside a `load`ed
   file is decorated with THAT file's line before it ever unwinds past the
   loading form, so the `(load ...)` call site's own decorator (seeing a
   message that already has a location) leaves it alone. *)
let message_has_location (msg : string) : bool =
  let n = String.length msg in
  let contains_at =
    let rec go i = i + 4 <= n && (String.sub msg i 4 = " at " || go (i + 1)) in
    go 0 in
  let all_digits i =
    i < n &&
    (let ok = ref true in
     for k = i to n - 1 do
       if not (msg.[k] >= '0' && msg.[k] <= '9') then ok := false
     done; !ok) in
  match String.rindex_opt msg ':' with
  | Some i -> contains_at && all_digits (i + 1)
  | None -> false

let with_form_location (e : expr) (f : unit -> 'a) : 'a =
  match e with
  | ELocated ((file, line), _) ->
      let relocate msg =
        if message_has_location msg then msg
        else Printf.sprintf "%s at %s:%d" msg file line in
      (try f () with
       | Failure msg -> failwith (relocate msg)
       | Capability_error msg -> raise (Capability_error (relocate msg)))
  | _ -> f ()

(* Initial capabilities from --grant (set by main.ml before init) *)
let initial_capabilities : capability list ref = ref []

(* Program arguments: everything after `--` on the pp command line (set by
   main.ml). Read by the `argv` primitive, which records an `argv:` trace
   cell so a node that observed them recomputes when they change. *)
let program_argv : string list ref = ref []

(* --stabilize: when true, init skips Hashtbl.clear thunk_store so
   clean thunks remain Evaluated and skip Store.hit on re-execute.
   Set false for cold runs and --once; true for stabilize iterations. *)
let keep_thunks = ref false

(* ---- Fenced-effect registry (Q3 / LAW 31) ----
   Scripting-tier `(fenced KIND SPEC)` registers an action here.  The
   reconciler/supervisor drains this list after convergent work, one action at
   a time, journaling intent/done around each. *)
let fenced_actions : (string * value) list ref = ref []

(* Island fetching (--fetch-islands / --update): runtime authority for the
   loader to run git and populate the island cache (LAW 24). NOT a user
   capability — procurement is the interpreter's job, and with it disabled
   (the default) island resolution never touches the network. *)
let island_fetch_enabled = ref false

(* Unknown-status policy set by --fenced-policy: what to do with a journaled
   fenced intent that has no matching done (a crash mid-action). Parsed once
   in main.ml; everything downstream matches exhaustively. *)
type fenced_policy = Retry | Abort | Ask

let fenced_policy : fenced_policy ref = ref Abort

let fenced_policy_name = function
  | Retry -> "retry"
  | Abort -> "abort"
  | Ask -> "ask"
