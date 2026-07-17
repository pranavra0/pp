(* pp runtime — shared mutable state used by both backends *)
include Effects
open Types
open Effect

type fenced_policy = Retry | Abort | Ask

type invocation = {
  source_roots : Paths.canonical list;
  initial_capabilities : Capability.t list;
  program_argv : string list;
  program_files : string list;
  program_bytecode : bool;
  initial_grant_specs : string list;
  program_reconcile_root : string option;
  program_supervise : bool;
  program_member_name : string option;
  program_desired_object : (string * string) option;
  gc_keep_epochs : int;
  fenced_policy : fenced_policy;
}

let invocation : invocation option ref = ref None
let invocation_get () : invocation =
  match !invocation with Some i -> i | None -> failwith "invocation not set"
type state = {
  mutable observe_all : bool;
  mutable observed_all : (string * string) list;
  mutable proc_observer : string -> string option;
  mutable probe_observer : string -> string option;
  mutable keep_thunks : bool;
  mutable fenced_actions : (string * value) list;
  mutable island_fetch_enabled : bool;
  mutable domain_cell_observer : string -> string -> string option;
}

let state = {
  observe_all = false;
  observed_all = [];
  proc_observer = (fun _ -> None);
  probe_observer = (fun _ -> None);
  keep_thunks = false;
  fenced_actions = [];
  island_fetch_enabled = false;
  domain_cell_observer = (fun _ _ -> None);
}

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
   against the current world before serving the stored result (SPEC LAW 21).

   Each node force pushes a fresh frame; every world-read during its evaluation
   is recorded into *all* active frames, so a parent's trace transitively
   subsumes the reads of nested (non-node) computation it forced. *)

(* Program-level observation collection for the reconciler's stratification
   check (LAW 30): when enabled (pp --reconcile), every recorded cell
   observation — whether or not a node frame is active — is also appended
   to [state.observed_all], so the reconciler can refuse a desired state
   whose computation read its own domain. *)

(* Record a (cell-id, observed-hash) world-read into every active trace frame.
   Deduplicated per frame on the (cell, hash) PAIR — not the cell alone: if one
   run observes the same cell with two different hashes (a file changed mid-run,
   a config key read under two scopes), both observations are kept, and a trace
   containing both can never verify — forcing a recompute, which is the only
   sound answer for a run that saw an inconsistent world. *)
let record_read (cell_id : string) (observed_hash : string) : unit =
  ignore (Effect.perform (Record_read (cell_id, observed_hash)));
  if Effect.perform Get_observe_all then
    state.observed_all <- (cell_id, observed_hash) :: state.observed_all

(* ---- Per-node sandbox (LAW 18) ----

   One slot per active node force, parallel to trace_stack. The directory is
   created lazily on the first `run` or scratch write inside the node and
   removed when the node's frame pops (every exit path). Scratch is node-local
   working memory: reads/writes inside it are neither capability-checked nor
   recorded in the trace — only values that the node returns escape. *)
let sandbox_counter = ref 0

let remove_tree (path : string) : unit =
  let entries = ref [] in
  Fswalk.walk ~root:path ~cb:(fun ~rel:_ ~path visit ->
    match visit with
    | Fswalk.Entry st -> entries := (path, st.Unix.st_kind = Unix.S_DIR) :: !entries
    | _ -> ());
  List.iter (fun (p, is_dir) ->
    try if is_dir then Unix.rmdir p else Sys.remove p with _ -> ())
    (List.rev !entries)

(* Innermost node's sandbox; created on demand when [create] is set. *)
let current_sandbox ~(create : bool) : string option =
  match Effect.perform Current_sandbox with
  | None -> None
  | Some slot ->
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
  if Filename.is_relative path then
    match Effect.perform Current_sandbox with
    | Some slot when (match !slot with Some _ -> true | None -> create) ->
        (match current_sandbox ~create with
         | Some d -> Some (Filename.concat d path)
         | None -> None)
    | _ -> None
  else None

(* ---- LAW 33 / LAW 26: config and handlers are observations, not identity ----

   The persistent node key covers code + free-var value hashes only (LAW 20).
   A node that reads `(config k)` or performs an effect has OBSERVED ambient
   state, so the read is recorded as a trace cell — `config:<key>` /
   `handler:<effect>` — and re-observed at hit time against the caller's
   current config/handler stacks, exactly like a file cell is re-observed
   against the current file contents. These helpers are the single code path
   for both the record (during a node run) and the re-observation (during a
   hit check), so the two can never disagree. *)

(* Process-domain cell observation hook — currently dormant. Nothing wires
   it, and nothing ever calls record_read with a Cell.Proc id either, so
   Store.observe_cell's `Cell.Proc` arm is unreachable dead weight:
   stdlib/domain-proc.pp's observe reads domain-state directly instead of
   going through a proc: cell at all. Left as the
   default no-op rather than removed: Cell.Proc itself stays as a cell
   kind (fs and proc keep their existing cell kinds even though only fs's
   is live), so this hook stays as its dormant counterpart rather than an
   asymmetric partial removal. *)

let observe_proc (name : string) : string option =
  state.proc_observer name

(* Probes: Store-facing re-observation hook, wired in main.ml
   (`Runtime.probe_observer := Primitives.probe_observe_for_store`) exactly
   like [proc_observer] above and for the same reason — Store.ml cannot
   depend on Primitives.ml directly (Primitives already depends on Store, so
   the reverse would be a module cycle), so the hook is the indirection. *)

let observe_probe (name : string) : string option =
  state.probe_observer name

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
  find (Effect.perform Get_config)

let observe_config (key : string) : string =
  match config_lookup key with
  | Some v -> hash_value (Backend.r.force v)
  | None -> config_absent_hash

let observe_handler (name : string) : string =
  match Effect.perform (Lookup_handler name) with
  | Some (_, h) -> h
  | None -> builtin_handler_hash

(* Record-side entry points; no-ops outside a node (no active trace frame). *)
let record_config_read (key : string) : unit =
  record_read (config_cell_id key) (observe_config key)

let record_handler_observation (name : string) : unit =
  record_read (handler_cell_id name) (observe_handler name)

(* ---- Loader authority — the runtime/traced split ----

   `load`/`load-module`/`island` run with the INTERPRETER's authority, not the
   user capability set: they are the loader, not user effects. That authority
   is bounded — the directories of the CLI-named programs, the working
   directory, and ~/.pp — so the loader is no longer an unbounded ambient
   read hole. Each loader read is recorded as a `runtime:file:` trace cell:
   it participates in cache VALIDITY (editing a loaded file invalidates the
   nodes that loaded it) but is excluded from the caller's hit-time authority
   requirement (cell_authorized passes runtime: cells unconditionally). *)

(* stdlib/domain-fs.pp and stdlib/domain-proc.pp
   must load from ANY cwd (--reconcile/--supervise are meant to work from
   wherever the user invokes pp, not just the repo root) — resolved
   relative to the RUNNING EXECUTABLE, not the cwd: dirname(realpath(argv0))
   is .../src (or .../bin under an install layout), and its sibling
   "stdlib" is where dune mirrors (or an install lays out) the actual
   stdlib/ tree. `bin/pp` is a symlink to `_build/default/src/main.exe`
   (the dev convention this repo's .envrc documents), so realpath resolves
   through it to .../_build/default/src/main.exe, whose sibling-of-parent
   is .../_build/default/stdlib — exactly where dune's `(source_tree
   stdlib)` mirrors the real stdlib/ directory for `dune runtest` too. *)
let stdlib_root () : string option =
  try
    let exe = Unix.realpath Sys.executable_name in
    let exe_dir = Filename.dirname exe in
    let candidate = Filename.concat (Filename.dirname exe_dir) "stdlib" in
    if Sys.file_exists candidate && Sys.is_directory candidate then Some candidate
    else None
  with _ -> None

(* SPEC LAW 23: the ONE cell-id canonicalization function,
   applied at every file:/tree:/stat:/tool:/runtime:file: construction site,
   every --grant path, and the loader bound — so two syntactically different
   paths naming the same inode collapse to one cell, closed at the cell
   layer: macOS /var vs /private/var, a
   symlinked source tree, and a trailing slash all name the same cell.

   Existing paths: made absolute, then realpath (symlinks resolved). Paths
   that do not (yet) exist — a write-target before its file is created —
   realpath the longest EXISTING prefix and append the remaining components
   lexically normalized ("." dropped, ".." pops the previous remaining
   component); this is why a write-target's cell id is stable across the
   file's creation. No trailing slash (root "/" excepted).

   NFC Unicode normalization is applied by the dependency-free [Nfc]
   normalizer after filesystem resolution. *)
let canonical_path_impl (p : string) : string =
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
  let normalized_tail =
    List.rev
      (List.fold_left (fun acc part ->
         match part with
         | "." -> acc
         | ".." -> (match acc with _ :: t -> t | [] -> acc)
         | x -> x :: acc)
         [] remaining)
  in
  let resolved =
    match normalized_tail with
    | [] -> real_existing
    | _ -> real_existing ^ "/" ^ String.concat "/" normalized_tail
  in
  Nfc.nfc_normalize resolved

let canonical_path (p : string) : Paths.canonical =
  Paths.canonicalize ~realpath:canonical_path_impl p

let loader_authorized (path : string) : bool =
  let p = canonical_path path in
  let home = try Sys.getenv "HOME" with Not_found -> "/tmp" in
  let roots = canonical_path (Filename.concat home ".pp") :: (invocation_get ()).source_roots in
  List.exists (fun r -> Paths.under ~root:r p) roots

let loader_read (path : string) : string =
  let canon = canonical_path path in
  if not (loader_authorized path) then
    failwith ("load: " ^ path
              ^ " is outside the interpreter's source roots (loader authority \
                 is bounded to the CLI-named programs' directories, the cwd, \
                 and ~/.pp)");
  let ic = open_in (canon :> string) in
  let content = really_input_string ic (in_channel_length ic) in
  close_in ic;
  record_read (Cell.(to_string (RuntimeFile (canon :> string)))) (hash_string content);
  content

(* ---- LAW 29: source locations on runtime errors, never doubled ----

   A runtime error escaping a form's evaluation should report THAT form's
   own file:line — unless it already carries one (Pp_error with pos = Some,
   from a deeper form or the reader), in which case it is left alone: a more
   specific location already won and must not be overwritten by an outer one.
   The already-located test is the typed [pos] field, not a scan of the
   message text.

   One implementation, shared by every driver that evaluates a sequence of
   located top-level-shaped forms: the top-level driver (repl.ml,
   execute_file/execute_file_bytecode, both backends), the tree-walker's
   `load` (evaluator.ml eval_expressions), and the VM's LOAD_FILE opcode
   (vm.ml). Applying it at `load` granularity too (not just the outermost
   top level) means an error inside a `load`ed
   file is decorated with THAT file's line before it ever unwinds past the
   loading form, so the `(load ...)` call site's own decorator (seeing a
   message that already has a location) leaves it alone. *)
let with_form_location (e : expr) (f : unit -> 'a) : 'a =
  match e with
  | ELocated ((file, line), _) ->
      let here = Some (file, line) in
      (try f () with
       (* A deeper form (or the reader) already attached a location — leave it. *)
       | Pp_error { pos = Some _; _ } as e -> raise e
       | Pp_error r -> raise (Pp_error { r with pos = here })
       (* Leaf raises are unlocated; wrap them here, at the innermost form.
          [kind] preserves whether the error may be node-cached — Capability
          errors may not (LAW 15). Capability_error keeps its distinct identity
          everywhere BELOW this boundary (nodes see it directly); only its
          user-facing rendering is unified through Pp_error here. *)
       | Failure msg -> raise (Pp_error { kind = Eval; msg; pos = here })
       | Capability_error msg -> raise (Pp_error { kind = Capability; msg; pos = here }))
  | _ -> f ()


(* --stabilize: when true, init skips Hashtbl.clear thunk_store so
   clean thunks remain Evaluated and skip Store.hit on re-execute.
   Set false for cold runs and --once; true for stabilize iterations. *)

(* ---- Fenced-effect registry (LAW 31) ----
   Scripting-tier `(fenced KIND SPEC)` registers an action here.  The
   reconciler/supervisor drains this list after convergent work, one action at
   a time, journaling intent/done around each. *)

(* Island fetching (--fetch-islands / --update): runtime authority for the
   loader to run git and populate the island cache (LAW 24). NOT a user
   capability — procurement is the interpreter's job, and with it disabled
   (the default) island resolution never touches the network. *)


let fenced_policy_name = function
  | Retry -> "retry"
  | Abort -> "abort"
  | Ask -> "ask"

(* ---- The in-language reconciler-domain protocol ----

   ONE registry for both hats of "a domain": a probe is a domain with BOTTOM
   write authority (dm_diff/dm_apply = None, dm_namespace = [] — nothing to
   converge, nothing to stratify); a full domain adds diff/apply and a
   namespace. `register-probe` (primitives.ml) is now sugar over
   `register-domain`, and `(probe name)`'s lookup / Store's re-observation
   hook both read this one table — stage 1's probe_registry generalized in
   place, not a parallel table. *)
type domain_entry = {
  dm_namespace : string list;
    (* Cell-id PREFIXES this domain owns, for stratification (LAW 30 full
       form) — []  for a probe (bottom write authority: nothing to
       stratify, core never converges it). fs supplies ["file:" ^ root;
       "tree:" ^ root; "stat:" ^ root]; proc supplies ["proc:"]. *)
  dm_observe : value;       (* () -> value; fresh every pass, never cached *)
  dm_diff : value option;   (* (observed, desired) -> plan, PURE; None = probe *)
  dm_apply : value option;  (* plan -> nil, NOT a node; None = probe *)
  dm_cap : Capability.t;
    (* The ONE capability consumed at registration: a probe's :read-cap
       (observe only) or a domain's :write-cap (observe AND apply both run
       under it — a write grant already covers read at the same scope, so
       no separate read-cap is threaded). Never re-exposed to user code. *)
  dm_observe_cell : value option;
    (* Optional (fn (sub) -> hash|nil): Store.observe_cell's O(1) targeted
       re-observation for a `domain:<name>:<sub>` cell (the proc_observer
       pattern generalized to third-party domains). *)
}

let domain_registry : (string, domain_entry) Hashtbl.t = Hashtbl.create 16

(* Store-facing hook for a `domain:<name>:<sub>` cell's re-observation, wired
   in main.ml (mirrors proc_observer/probe_observer just below) — Store
   cannot depend on Primitives directly (module-cycle reasons identical to
   those hooks). *)

let observe_domain_cell (name : string) (sub : string) : string option =
  state.domain_cell_observer name sub

(* Per-pass pinned probe results: cleared at exactly the three points the
   watch loop clears Store.run_pins (main.ml) — probes are LAW 38's declared-
   nondeterminism mechanism, so a value must never survive past the pass
   that observed it (unlike sealed_pins below, which share the same clearing
   points for a completely different reason — per-run read consistency,
   not volatility). *)
let probe_values : (string, value) Hashtbl.t = Hashtbl.create 16

(* ---- Sealed cells: in-memory-only bytes for a CapSecret-covered read ----

   A read covered by CapSecret and NOT by CapFilesystem returns VSealed and
   pins the raw bytes here (cell-id -> bytes), keyed exactly like
   Store.run_pins but NEVER touching store_blob/the CAS — that is the whole
   point: secret bytes must never land under
   ~/.pp/store. Per-run consistency: the first read of a sealed cell in
   a run pins its bytes; later reads of the SAME cell in the SAME run serve
   the pin, so one run can never observe two versions of one secret. Cleared
   at exactly the three points Store.run_pins is cleared (main.ml's watch
   loop) — same points, different justification per cell kind. *)
let sealed_pins : (string, string) Hashtbl.t = Hashtbl.create 16

let with_top_level ~f x =
  try f x with
  | effect Get_capabilities, k -> Effect.Deep.continue k (invocation_get ()).initial_capabilities
  | effect Get_config, k -> Effect.Deep.continue k []
  | effect Get_handlers, k -> Effect.Deep.continue k []
  | effect (Lookup_handler _), k -> Effect.Deep.continue k None
  | effect (Record_read _), k -> Effect.Deep.continue k ()
  | effect In_node, k -> Effect.Deep.continue k false
  | effect Current_sandbox, k -> Effect.Deep.continue k None
  | effect Get_domain, k -> Effect.Deep.continue k None
  | effect Get_observe_all, k -> Effect.Deep.continue k true
