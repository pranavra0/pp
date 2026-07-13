(* pp evaluator — lazy, call-by-need evaluator with thunks *)

open Types
open Hasher
open Runtime

(* ---- Evaluation State ---- *)

(* Content-addressed thunk store is now in Runtime. *)

(* Create or retrieve a content-addressed thunk.
   Two thunks with the same (expr, env, capabilities) are the SAME thunk.
   Uses env.env_hash for O(1) environment identity — no recursive traversal. *)
let make_thunk_ca (expr : expr) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
  let h = hash_concat ["thunk"; Hasher.hash_expr expr; env.env_hash; caps_hash; cfg_hash; handlers_hash ()] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = None; thunk_loc = None; config_hash = cfg_hash; thunk_persist = false; node_fv = []; node_caps = [] } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Like make_thunk_ca, but the thunk carries a type annotation that is
   checked when the thunk is forced (mirrors the VM's MAKE_THUNK with
   type_ann, vm.ml). The annotation participates in the content hash so a
   typed thunk is never conflated with an untyped thunk over the same expr. *)
let make_thunk_ca_typed (expr : expr) (ty : expr) (loc : (string * int) option) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
  let h = hash_concat ["thunk-typed"; Hasher.hash_expr expr; Hasher.hash_expr ty; env.env_hash; caps_hash; cfg_hash; handlers_hash ()] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = Some ty; thunk_loc = loc; config_hash = cfg_hash; thunk_persist = false; node_fv = []; node_caps = [] } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Runtime check for gradual type annotations. Shared by both backends (the
   VM calls it too), so they fail identically by construction. *)
let check_type (v : value) (ty : expr) (loc : (string * int) option) : unit =
  let type_name =
    match ty with
    | ESymbol s -> s
    | ELiteral (VSymbol s) | ELiteral (VKeyword s) -> s
    | _ -> "unknown"
  in
  let ok =
    match type_name with
    | "int" -> (match v with VInt _ -> true | _ -> false)
    | "string" -> (match v with VString _ -> true | _ -> false)
    | "bool" -> (match v with VBool _ -> true | _ -> false)
    | "nil" -> (match v with VNil -> true | _ -> false)
    | _ -> true  (* unknown types pass for v1 *)
  in
  if not ok then
    let loc_str = match loc with
      | Some (file, line) -> Printf.sprintf " at %s:%d" file line
      | None -> "" in
    failwith (Printf.sprintf "type mismatch: expected %s, got %s%s"
                type_name (string_of_value v) loc_str)

(* LAW 23b: whether a set of capabilities permits reading a trace cell. Used
   to gate cache hits on the transitive read closure. The match is
   exhaustive over Cell.t so adding a cell kind forces an authority decision
   here. Parameterized on the capability set (rather than reading
   !current_capabilities directly) because "the caller's capabilities" for a
   node hit-gate is, per M3's redefinition of LAW 23b, the forcing thunk's
   node_caps — its ambient AT CREATION — not necessarily whatever is live in
   current_capabilities at force time (with-caps can have narrowed the
   dynamic ambient in between). *)
let cell_authorized_for (caps : capability list) (cell_id : string) : bool =
  let has_fs_read path =
    List.exists (fun cap -> Capabilities.check_fs_read cap path) caps
  in
  match Cell.of_string cell_id with
  | Cell.File path -> has_fs_read path
  (* A coarse tree observation (run effect, Q2) is covered by an fs-read
     grant over the root. *)
  | Cell.Tree root -> has_fs_read root
  (* A tool observation came from a `run`; serving a result that embeds
     one requires process authority, not an fs grant over the binary. *)
  | Cell.Tool _ ->
      List.exists (function CapProcess -> true | _ -> false) caps
  (* A file-predicate observation (file-exists?/dir?) discloses presence,
     so serving it requires the same fs-read authority as recording it. *)
  | Cell.Stat path -> has_fs_read path
  (* No user authority attaches: config/handler are ambient (LAW 33/26),
     runtime:file loader reads ran under interpreter authority (Q6/D8c),
     env/argv/proc are program-level inputs. Unknown cells never verify, so
     authorizing them is moot. *)
  | Cell.RuntimeFile _ | Cell.Env _ | Cell.Argv
  | Cell.Config _ | Cell.Handler _ | Cell.Proc _ | Cell.Unknown _ -> true
  (* M4 probes: authority-exempt at the hit gate, like runtime:/config:/
     handler:/proc: above — deliberately, not an oversight. The read_cap's
     authority was already consumed ONCE, at probe evaluation time (under
     with_ref current_capabilities [read_cap], PLAN-m4-cells.md), not at
     every read; gating a CACHE HIT on it again would re-require an
     authority the reading caller structurally cannot hold any other way
     (probe reads are capability-free at the read site by design — LAW 37's
     whole point is that the DECLARED nondeterminism mechanism, not the
     reader, carries the authority). LAW 23b's transitive-closure concern
     (a narrow caller laundering a broad SECRET read through an aggregator)
     does not apply here: a probe's value is not confidential — sealed
     cells are the confidentiality mechanism, and unlike Cell.Sealed below,
     Cell.Probe never gates on CapSecret. Any caller who can force the node
     at all may observe what the probe produced. *)
  | Cell.Probe _ -> true
  (* M4 sealed cells: the opposite choice from Probe above — a sealed read
     is confidential, so a hit requires the caller to independently hold a
     covering CapSecret grant over the path, exactly like Cell.File requires
     fs-read authority. This is what makes LAW 23b's transitive-closure
     check and LAW 23c's `pp why` redaction protect a secret exactly the way
     they already protect a narrow fs grant: a caller without the secret
     grant cannot hit a node whose closure read it, even through an
     aggregator (tests/044's narrow-caller case). *)
  | Cell.Sealed path ->
      List.exists (fun cap -> Capabilities.check_secret cap path) caps
  (* Q13: a third-party domain's own sub-cell. Authorization is
     cap_subseteq of the REGISTERED write-cap against the caller's held
     set — zero new authority code, the same narrowing check with-caps
     uses. An unregistered (in THIS process) domain name never verifies —
     the sound, conservative default, like Cell.Unknown. *)
  | Cell.Domain { name; sub = _ } ->
      (match Hashtbl.find_opt Runtime.domain_registry name with
       | Some entry -> Capabilities.cap_subseteq entry.Runtime.dm_cap caps
       | None -> false)

(* Trace replay for an already-Evaluated persistent node: replay its stored
   trace reads into the active trace frames so the caller's trace transitively
   captures this node's world-reads (same mechanism as Store.hit's hit-replay).
   [key_of] is the backend's node-key function (node_key_of / vm_node_key). *)
let replay_node_reads (t : thunk) (key_of : thunk -> string) : unit =
  if t.thunk_persist && !Runtime.trace_stack <> [] then
    let traces = Store.load_traces ~key:(key_of t) in
    List.iter (fun tr ->
      List.iter (fun (c, h) -> Runtime.record_read c h) tr.Store.tr_reads
    ) traces

(* Run a persistent node's body and store the result (LAW 21) or the failure
   (LAW 28) with its verifying trace. Shared by the tree-walker's force, the
   trampoline, and the VM's force_node_thunk — the node caches identically
   however it is demanded. [run] executes the body; the caller owns any
   backend-specific bookkeeping (force_depth, operand-stack isolation). *)
let run_node_body ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  (* Node capture (Q11): the miss recompute — and everything it forces —
     runs under the FORCING THUNK's captured ambient, not whatever is live
     in current_capabilities right now (with-caps may have narrowed the
     dynamic ambient between this node's creation and this force). with_ref
     restores current_capabilities on every exit, exception included, so
     this composes cleanly with the try/with below. *)
  with_ref current_capabilities t.node_caps (fun () ->
  t.thunk_status <- Evaluating;
  (* The trace frame captures the world-reads (slurp, read-file, …) this node
     makes as (cell-id, observed-hash) pairs. Popped on every exit — normal or
     exceptional — so a raised error never leaks a dangling frame. *)
  let frame = Runtime.push_trace_frame () in
  let result =
    try
      let r = run () in
      Runtime.pop_trace_frame ();
      r
    with
    | Failure msg as e ->
        Runtime.pop_trace_frame ();
        (* LAW 28: store a FAILING trace — the error value plus the reads made
           up to the failure — so a re-force with unchanged inputs re-serves the
           failure, and re-runs only when a read changes. D16: reset the status
           off `Evaluating` so the next force reports the real error, not a fake
           "infinite recursion". A Capability_error is not a Failure and is
           never memoized (LAW 15/20). *)
        let errval = VString msg in
        let err_hash = Hasher.hash_value errval in
        (try Store.store_object ~key:err_hash ~value:errval with _ -> ());
        (try Store.store_trace ~key ~outcome:Failed ~result_hash:err_hash
               ~reads:(List.rev !frame) with _ -> ());
        t.thunk_status <- Unevaluated;
        raise e
    | e ->
        Runtime.pop_trace_frame ();
        t.thunk_status <- Unevaluated;
        raise e
  in
  (* Result ban (LAW 20 node-boundary, export side — adversarial-review
     amendment; extended M4/LAW 39 to VSealed): a node may not RETURN a
     capability or a sealed value. Checked before any store write, so a
     would-be-cached VCapability/VSealed never reaches the store; not
     memoized as a failure either (mirrors Capability_error's own
     not-memoized discipline — an authority-shaped outcome is not cache
     material). Otherwise `(node (current-capabilities))` would be an
     ambient-dependent result invisible to both the key and the trace (a
     determinism hole), and a broad cap (or a secret) could ride a result out
     to a narrower/unauthorized caller — the node boundary must be
     symmetric. *)
  if Hasher.contains_authority result then begin
    t.thunk_status <- Unevaluated;
    if Hasher.contains_sealed result then
      raise (Capability_error "a node may not return a sealed value")
    else
      raise (Capability_error "a node may not return a capability")
  end;
  (match t.type_ann with
   | Some ty -> check_type result ty t.thunk_loc
   | None -> ());
  t.thunk_status <- Evaluated result;
  let result_hash = Hasher.hash_value result in
  (* Objects are content-addressed by result hash; the trace maps the node
     key to that result plus the reads that justify it. *)
  (try Store.store_object ~key:result_hash ~value:result with _ -> ());
  (try Store.store_trace ~key ~outcome:Ok ~result_hash
         ~reads:(List.rev !frame) with _ -> ());
  (* --check (LAW 38): run the body a second time under a throwaway trace
     frame; a different result hash means the node observed something no
     cell captured — volatile, and unsafe to cache. *)
  if !Store.check_mode then begin
    ignore (Runtime.push_trace_frame ());
    let r2 =
      try run ()
      with e -> Runtime.pop_trace_frame (); raise e
    in
    Runtime.pop_trace_frame ();
    if Hasher.hash_value r2 <> result_hash then begin
      incr Store.volatile_count;
      Printf.eprintf
        "[check] volatile node %s: an identical run produced a different result hash\n%!"
        (Store.short_key key)
    end
  end;
  result)

(* Serve a resolved Store.hit_result the same way in every miss-arm variant
   below: a verified hit (gated on LAW 23b authority), a re-served memoized
   failure (LAW 28), or [None] on Miss (caller decides what to do). *)
let serve_hit ~(t : thunk) (h : Store.hit_result) : value option =
  match h with
  | Store.HitOk cached ->
      t.thunk_status <- Evaluated cached;
      Some cached
  | Store.HitFailed errval ->
      (match errval with
       | VString msg -> failwith msg
       | _ -> failwith "node failed (cached)")
  | Store.Miss -> None

(* Force a persistent node through the store: serve a verified hit (gated on
   the caller's authority over the trace's read closure, LAW 23b), re-serve a
   memoized failure (LAW 28), or run and store on a miss.

   Phase 3 miss-arm integration (docs/PLAN-phase3-parallel.md, "singleton,
   width from policy"): under [Race n] with n > 1, a singleton miss is worth
   forking — n redundant (key, run) forks of the SAME job race each other
   (sound: LAW 37 nodes are deterministic), the parent never reads a value
   from any of them, and re-enters Store.hit afterward exactly as the batch
   path does — a hit if some child won, a Miss (falling through to the
   ordinary in-process run below) if every child died. Under [Serial] or
   [Parallel _], a LONE miss stays in-process (width 1): forking a single job
   buys nothing (there is no second worker to race or overlap with) — only a
   force-deep BATCH benefits from forking, and that path (Primitives
   force-deep) dispatches its own batch before any of its members ever
   reaches this function as a Miss. *)
let force_node ~(key : string) ~(run : unit -> value) (t : thunk) : value =
  Stabilize.register_node_key ~key ~thunk:t;
  (* LAW 23b (M3 redefinition): "the caller's capabilities" for the hit gate
     is THIS thunk's node_caps — captured at this process's creation of this
     `(node e)` occurrence — not necessarily current_capabilities right now.
     Absent with-caps the two are always equal (node_caps is populated from
     current_capabilities at creation and current_capabilities never changes
     without with-caps), so this is byte-for-byte the pre-M3 behavior for
     tests/011/013/017. *)
  let authorized = cell_authorized_for t.node_caps in
  match serve_hit ~t (Store.hit ~key ~authorized) with
  | Some v -> v
  | None ->
      (match !Scheduler.policy with
       | Scheduler.Race n when n > 1 ->
           let job = { Scheduler.j_key = key;
                       j_run = (fun () -> run_node_body ~key ~run t);
                       j_width = n; j_thunk = t } in
           Scheduler.dispatch_batch [job];
           (match serve_hit ~t (Store.hit ~key ~authorized) with
            | Some v -> v
            | None ->
                (* Every racing worker died: degrade to the ordinary serial
                   path — never a wrong answer, never a hang. *)
                run_node_body ~key ~run t)
       (* A lone miss stays in-process under every OTHER policy too,
          including [Remote _]: spinning up a cluster-member subprocess for
          a single node buys nothing (there is no sibling to overlap with,
          same reasoning as Serial/Parallel above) — only a force-deep BATCH
          (collect_unevaluated_nodes, primitives.ml) is worth shipping. *)
       | Scheduler.Serial | Scheduler.Parallel _ | Scheduler.Race _
       | Scheduler.Remote _ ->
           run_node_body ~key ~run t)

(* Module exports: the bindings of [bindings] not present in [base]
   (insertion order preserved). With [dedup], each name is exported once —
   newest binding wins (a value def's backpatched poison pre-binding must not
   shadow the real binding). *)
let new_bindings ?(dedup = false) ~(base : (string * value) list)
    (bindings : (string * value) list) : (string * value) list =
  let rec collect all acc =
    match all with
    | [] -> List.rev acc
    | (n, v) :: rest ->
        if List.exists (fun (pn, _) -> pn = n) base
           || (dedup && List.exists (fun (an, _) -> an = n) acc) then
          collect rest acc
        else
          collect rest ((n, v) :: acc)
  in
  collect bindings []

(* letrec* poison for value defs in blocks: a fresh (non-content-addressed)
   thunk pre-bound at block entry so the whole block sees the binding; forcing
   it before the def executes raises, and the def backpatches it in place. The
   error expression compiles/evaluates to the SAME text in both backends. *)
let poison_expr (name : string) : expr =
  EApply (ESymbol "error",
          [ELiteral (VString (name ^ ": referenced before its definition"))])

let poison_thunk (name : string) (env : env) : value =
  make_thunk (poison_expr name) env

(* ---- Force: evaluate a thunk on demand ---- *)

(* Depth limit before switching to heap-allocated trampoline.
   OCaml's default stack handles ~10k small frames; 2000 gives
   ample headroom while keeping the trampoline nesting shallow
   even for 10^6-deep recursion (~500 trampoline entries). *)
let max_force_depth = 2000
let force_depth = ref 0



(* Main force entry-point: uses native stack for shallow chains,
   switches to trampoline when depth exceeds threshold. *)
let rec force (v : value) : value =
  incr force_depth;
  match v with
  | _ when !force_depth > max_force_depth ->
      let saved = !force_depth in
      force_depth := 0;
      let r = trampoline_force v in
      force_depth := saved;
      decr force_depth;
      r
  | VThunk t ->
      (match t.thunk_status with
       | Evaluated result ->
           decr force_depth;
           replay_node_reads t node_key_of;
           force result
       | Evaluating ->
           decr force_depth;
           failwith "infinite recursion detected (forcing a thunk already being evaluated)"
       | Unevaluated ->
           (* Persistent nodes route through the store. Identity is the
              LAW 20 node key (code + free-var value hashes); the trace decides
              validity. A stale trace falls through to recompute. *)
           if t.thunk_persist then
             let nk = node_key_of t in
             let run () =
               match t.vm_code with
               | Some (bc, code_offset, frames) ->
                   !Primitives.vm_run_thunk_ref bc code_offset frames
               | None ->
                   eval t.thunk_expr t.thunk_env
             in
             (match force_node ~key:nk ~run t with
              | result -> decr force_depth; force result
              | exception e -> decr force_depth; raise e)
           else
             evaluate_and_store_no_key t)
  | _ ->
      decr force_depth;
      v

and evaluate_and_store_no_key (t : thunk) : value =
  t.thunk_status <- Evaluating;
  let result =
    try
      match t.vm_code with
      | Some (bc, code_offset, frames) ->
          !Primitives.vm_run_thunk_ref bc code_offset frames
      | None ->
          eval t.thunk_expr t.thunk_env
    with e ->
      (* D16: an ephemeral thunk that raised must not be left `Evaluating`, or
         the next force misreports "infinite recursion". Reset and re-raise the
         real error (ephemeral thunks are not failure-cached). *)
      t.thunk_status <- Unevaluated;
      decr force_depth;
      raise e
  in
  (match t.type_ann with
   | Some ty -> check_type result ty t.thunk_loc
   | None -> ());
  t.thunk_status <- Evaluated result;
  decr force_depth;
  force result

(* LAW 20: a node's persistent key is its code structure plus the *value* hashes
   of the free variables it references (forced, call-by-value — the key cannot
   exist before its inputs' values do). This deliberately omits the whole-env
   hash (so rebinding an unrelated global does not re-key the node), the
   capability set (authority gates *access* to a hit — LAW 23 — never identity),
   and the ambient config/handler stacks: a config value or handler the node
   actually observed is recorded in its trace as a `config:`/`handler:` cell
   and governs validity, not identity (LAW 33/26). *)
and node_key_of (t : thunk) : string =
  let e = t.thunk_expr in
  let fv_parts =
    Types.SS.elements (Types.free_vars e)
    |> List.map (fun name ->
         match lookup_env t.thunk_env name with
         | Some v ->
             (* M3 free-var ban (LAW 20 node-boundary, import side; extended
                M4/LAW 39 to VSealed): if the forced value contains a
                VCapability or VSealed (Hasher.contains_authority — never
                forces an already-Unevaluated thunk, LAW 14), the key can
                never be computed — raise Capability_error naming the
                variable, rather than silently keying on (and thereby
                smuggling identity information about) a capability or secret.
                If forcing itself raises Capability_error, propagate it
                as-is; any OTHER exception falls back to hashing the
                unforced value (pre-existing behavior, unrelated to this
                ban). *)
             let hv =
               match force v with
               | fv ->
                   if Hasher.contains_authority fv then
                     raise (Capability_error
                       (Printf.sprintf
                          "node: free variable '%s' may not be or contain a %s" name
                          (if Hasher.contains_sealed fv then "sealed value" else "capability")));
                   Hasher.hash_value fv
               | exception e ->
                   (match e with
                    | Capability_error _ -> raise e
                    | _ -> Hasher.hash_value v)
             in
             hash_concat ["fv"; name; hv]
         | None -> hash_concat ["fv-unbound"; name])
  in
  hash_concat (["node-key"; Hasher.hash_expr e] @ fv_parts)

(* Remote placement (docs/PLAN-m5-distribution.md "Remote placement"): a
   node is data-closed iff every free var's FORCED value re-encodes under
   Codec.encode_value — the store's own non-data predicate (codec.ml),
   reused verbatim at this new decision point rather than duplicated.
   Mirrors node_key_of's own free-var walk/force (so "can this key be
   computed" and "can this node be shipped" agree on what counts as a free
   var) but never raises: a free var that forces to a capability/sealed
   value (node_key_of's own ban above) or that raises for any other reason
   is conservatively treated as NOT data-closed — the degrade-to-local
   posture, never a crash and never a wrong ship. An unbound name (a
   reference to a global/primitive function that initial_env never even
   populated) needs nothing shipped, so it never blocks shipping the node
   itself.

   VBuiltin is a documented, necessary carve-out to the literal codec
   check: `Primitives.initial_env` binds EVERY primitive into the base
   env (repl.ml), so an ordinary reference to `slurp`/`string-append`/etc.
   — present in nearly every real node body — resolves via [lookup_env]
   exactly like a captured user value would, and forcing it yields a
   VBuiltin, which [Codec.encode_value] correctly refuses (it is code, the
   store's non-data law). But a bare reference to a global primitive is
   NOT "shipping code" the way a captured VClosure over user state would
   be: it is part of the identical program source both sides already run,
   resolved identically by construction (the same pp binary's own builtin
   table) — the exact "no code crosses the wire" invariant the source-hash
   check already establishes at a coarser grain. A genuinely captured
   VClosure is deliberately NOT exempted here — that free var really would
   need code shipped, so it correctly still fails the encode check below,
   exactly like Codec.encode_value already treats it (the "free var is a
   closure stays local" contract scenario). *)
and is_data_closed (t : thunk) : bool =
  Types.SS.for_all (fun name ->
    match lookup_env t.thunk_env name with
    | None -> true
    | Some v ->
        (try
           match force v with
           | VBuiltin _ -> true
           | fv -> Codec.encode_value fv <> None
         with _ -> false))
    (Types.free_vars t.thunk_expr)

(* ---- Main Evaluator (non-tail) ---- *)

and eval (e : expr) (env : env) : value =
  Primitives.current_env_ref := env;
  eval_tail e env (fun v -> v)

(* ---- Tail-position evaluator ---- *)
(* eval_tail e env k: evaluates e in tail position with continuation k.
   The continuation k is threaded through tail calls without growing the
   OCaml stack — this is how TCO works. *)

and eval_tail (e : expr) (env : env) (k : value -> value) : value =
  Primitives.current_env_ref := env;
  match e with
  | ELiteral v -> k v

  | ESymbol name ->
      (match lookup_env env name with
       | Some v -> k (force v)
       | None ->
           (match Primitives.lookup name with
            | Some v -> k v
            | None -> failwith ("unbound symbol: " ^ name)))

  | EIf (cond, then_e, else_e) ->
      (* Condition is non-tail; branches are tail *)
      (match force (eval cond env) with
       | VBool true -> eval_tail then_e env k
       | VBool false -> eval_tail else_e env k
       | VNil -> eval_tail else_e env k
       | _ -> eval_tail then_e env k)

  | ELet (bindings, body) ->
      (* Mutual let: all bindings visible in every RHS (LAW 1).
         Create thunks with outer env, build mutual env, then backpatch
         each thunk's env so they see each other when forced. *)
      let thunks = List.map (fun (name, binding_expr) ->
        (name, make_thunk_ca binding_expr env)
      ) bindings in
      let env_mutual = List.fold_left (fun e (name, thunk) ->
        extend_env e name thunk
      ) env thunks in
      List.iter (fun (_, thunk) ->
        match thunk with
        | VThunk t -> t.thunk_env <- env_mutual
        | _ -> ()
      ) thunks;
      eval_tail body env_mutual k

  | EFn (params, body) ->
      k (make_closure ~name:None params body (ref env))

  | EApply (fn_expr, arg_exprs) ->
      (* Strict application (Q1): force fn and all args before calling.
         This is call-by-value: arguments are evaluated before the body runs. *)
      let fn_val = force (eval fn_expr env) in
      let arg_vals = List.map (fun arg_expr -> force (eval arg_expr env)) arg_exprs in
      apply_tail fn_val arg_vals env k

  | EQuote e ->
      k (Types.quote_to_value e)

  | EForce e ->
      (* EForce in tail position: eval the inner expression in tail position,
         then force the result and pass to k *)
      eval_tail e env (fun v -> k (force v))

  | EDelay e ->
      k (make_thunk_ca e env)

  | ENode e ->
      let thunk_val = make_thunk_ca e env in
      (match thunk_val with
       | VThunk t ->
           t.thunk_persist <- true;
           (* Node capture (Q11): the ambient at THIS creation, unconditionally
              — never left at the [] default (see Types.thunk.node_caps). Safe
              to re-assign even when make_thunk_ca returned an ALREADY-cached
              physical thunk (its content hash folds in caps_hash, so a hit
              here only happens when the ambient at that prior creation
              hashed the same). *)
           t.node_caps <- !current_capabilities
       | _ -> ());
      k thunk_val

  | EDefNode (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

  | EDo exprs ->
      (* All but last are non-tail; last is tail.
         Uses a local env ref for threading — NOT current_env_ref,
         because inner evaluations would clobber it. *)
      let env_ref = ref env in
      (* letrec* prologue: pre-bind every value def to a poison thunk so the
         whole block sees the binding (LAW 4); its def backpatches it. *)
      let poisons : (string, value) Hashtbl.t = Hashtbl.create 4 in
      List.iter (function
        | EDefValue (name, _) ->
            let p = poison_thunk name !env_ref in
            Hashtbl.replace poisons name p;
            env_ref := extend_env !env_ref name p
        | _ -> ()) exprs;
      let rec go = function
        | [] -> k VNil
        | [last] -> eval_tail last !env_ref k
        | (EDef (name, params, body)) :: rest ->
            let closure = make_closure ~name:(Some name) params body env_ref in
            env_ref := extend_env !env_ref name closure;
            go rest
        | (EDefNode (name, params, body)) :: rest ->
            let closure = make_closure ~name:(Some name) params body env_ref in
            env_ref := extend_env !env_ref name closure;
            go rest
        | (EDefValue (name, rhs)) :: rest ->
            let v = eval rhs !env_ref in
            (match Hashtbl.find_opt poisons name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            env_ref := extend_env !env_ref name v;
            go rest
        | (EImport mod_expr) :: rest ->
            let mod_val = force (eval mod_expr !env_ref) in
            (match mod_val with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> failwith "import expects a module value")
        | (ELoad path) :: rest ->
            (* `~source:path`: the loaded file's OWN path, so its top-level
               forms are located against it (not the reader's "<?>"
               default) — LAW 29/D12, closed via eval_expressions below,
               which per-form-locates each of the loaded file's forms.
               Macro expansion (M3): routed through the shared hook so a
               `load`ed file's macros are visible to the rest of THIS
               file's forms and vice versa (load is sequential evaluation,
               one shared macro table — Macro.ml's documented decision). *)
            let contents = Runtime.loader_read path in
            let exprs = !Primitives.expand_toplevel_ref
                          (Reader.read_string ~source:path contents) in
            ignore (eval_expressions exprs env_ref);
            go rest
        | (ELoadModule path) :: rest ->
            (match eval_module_file path with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
        | e :: rest ->
            let result = force (eval e !env_ref) in
            (match result with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> go rest)
      in
      go exprs

  | EWithCaps (cap_expr, body) ->
      (* REPLACES the dynamic ambient with exactly the requested cap for the
         body's extent (never a union — that was `effect`'s widening
         backdoor, removed in M3), gated by cap_subseteq against the CURRENT
         ambient (not the root grant), so narrowing composes even when code
         lexically retains a broader value (PLAN-m3-attenuation.md). with_ref
         restores current_capabilities on every exit, exception included
         (LAW 27). *)
      let cap_val = force (eval cap_expr env) in
      let requested =
        match cap_val with
        | VCapability c -> c
        | _ -> failwith "with-caps expects a capability value"
      in
      if not (Capabilities.cap_subseteq requested !current_capabilities) then
        raise (Capability_error Capabilities.err_with_caps_widen);
      with_ref current_capabilities [requested]
        (fun () -> eval_tail body env k)

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      k (perform_effect name forced_args)

  | EWithHandler (handlers, body) ->
      let new_handlers = List.map (fun (name, handler_expr) ->
        let handler_val = force (eval handler_expr env) in
        (name,
         (fun args -> apply handler_val args env),
         hash_value handler_val)   (* D17: handler identity in the key *)
      ) handlers in
      with_ref handler_stack (new_handlers @ !handler_stack)
        (fun () -> eval_tail body env k)

  | EDef (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

  | EDefValue (_, rhs) ->
      (* Bare expression position: evaluate the RHS and return it; binding is
         the job of the enclosing block / top level (mirrors EDef, which
         returns its closure without binding here). *)
      k (eval rhs env)

  | ELetStar (bindings, body) ->
      let rec nest env' = function
        | [] -> eval_tail body env' k
        | (name, expr) :: rest ->
            let thunk = make_thunk_ca expr env' in
            let env'' = extend_env env' name thunk in
            nest env'' rest
      in
      nest env bindings

  | EModule body_exprs ->
      let base_env = Primitives.initial_env () in
      let mod_env = ref base_env in
      (* letrec* prologue for value defs, as in EDo. *)
      let poisons : (string, value) Hashtbl.t = Hashtbl.create 4 in
      let prebound_env = List.fold_left (fun acc e ->
        match e with
        | EDefValue (name, _) ->
            let p = poison_thunk name acc in
            Hashtbl.replace poisons name p;
            extend_env acc name p
        | _ -> acc) !mod_env body_exprs in
      mod_env := prebound_env;
      let final_env = List.fold_left (fun (env_acc : env) e ->
        match e with
        | EDef (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefNode (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefValue (def_name, rhs) ->
            let v = eval rhs env_acc in
            (match Hashtbl.find_opt poisons def_name with
             | Some (VThunk t) -> t.thunk_status <- Evaluated v
             | _ -> ());
            extend_env env_acc def_name v
        | EImport mod_expr ->
            let mod_val = force (eval mod_expr env_acc) in
            (match mod_val with
             | VEnvMap bindings ->
                 List.fold_left (fun e (n, v) -> extend_env e n v) env_acc bindings
             | _ -> failwith "import within module expects a module value")
        | _ ->
            ignore (force (eval e env_acc));
            env_acc
      ) !mod_env body_exprs in
      k (VEnvMap (new_bindings ~dedup:true ~base:base_env.bindings final_env.bindings))

  | EImport mod_expr ->
      let mod_val = force (eval mod_expr env) in
      k mod_val

  | ELoad path ->
      (* M3 defmacro: same shared-expansion-hook treatment as EDo's ELoad
         arm above. *)
      let contents = Runtime.loader_read path in
      let exprs = !Primitives.expand_toplevel_ref
                    (Reader.read_string ~source:path contents) in
      let env_ref = ref env in
      k (eval_expressions exprs env_ref)

  | ELoadModule path ->
      k (eval_module_file path)

  | ELocated (loc, ETyped (e, ty)) ->
      (* Mirror the compiler (compiler.ml ELocated+ETyped): a located
         annotation becomes a typed thunk carrying the location. *)
      k (make_thunk_ca_typed e ty (Some loc) env)
  | ELocated (_, e) -> eval_tail e env k
  | ETyped (e, ty) ->
      (* Type annotations defer evaluation into a thunk whose result is
         checked at force time — same semantics as the VM (compiler.ml
         emit_thunk_region + vm.ml FORCE/check_type). *)
      k (make_thunk_ca_typed e ty None env)
  | EIsland (uri, pin) ->
      (* D2: resolve the inline pin to the immutable cached tree (verified
         against the pin on every resolve), then evaluate its entry.pp as a
         module. The pin is part of this expression's hash, so island
         identity is structural (LAW 20) — no trace cell. *)
      let tree = Island.resolve ~uri ~pin in
      k (eval_module_file (Island.entry_file tree))
  | EWithConfig (map_expr, body) ->
      let cfg = force (eval map_expr env) in
      (match cfg with
       | VMap _ ->
           with_ref config_stack (cfg :: !config_stack)
             (fun () -> eval_tail body env k)
       | _ -> failwith "with-config expects a map")
  | EConfig (key_expr, default_opt) ->
      let key_val = force (eval key_expr env) in
      let key_name = match key_val with
        | VString s | VKeyword s | VSymbol s -> s
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      (* LAW 33: reading config inside a node is an observation — recorded as a
         `config:<key>` trace cell (absence included), never part of the key. *)
      Runtime.record_config_read key_name;
      (match Runtime.config_lookup key_name with
       | Some v -> k v
       | None ->
           (match default_opt with
            | Some d -> eval_tail d env k
            | None -> k VNil))

(* ---- Function Application (non-tail) ---- *)

and apply (fn : value) (args : value list) (env : env) : value =
  apply_tail fn args env (fun v -> v)

(* ---- Tail-position application ---- *)
(* apply_tail fn args env k: applies fn to args, evaluates the body in
   tail position with continuation k. This is the engine of TCO: the
   continuation k is passed through to eval_tail on the function body,
   so a tail-call chain never grows the OCaml stack. *)

and apply_tail (fn : value) (args : value list) (env : env) (k : value -> value) : value =
  match fn with
  | VClosure { fn_name; params; body; env = closure_env; _ } ->
      if List.length params <> List.length args then begin
        let fname = match fn_name with Some n -> n | None -> "#<fn>" in
        failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d"
                    fname (List.length params) (List.length args))
      end;
      let env' = List.fold_left2 (fun e param arg ->
        extend_env e param arg  (* arg is already a thunk *)
      ) !closure_env params args in
      eval_tail body env' k

  | VBuiltin (_, f) ->
      (* No re-wrapping of the error text: primitives name themselves in their
         own messages, and the VM calls builtins unwrapped — wrapping here made
         the two backends' error output differ (and mangled user `error`
         messages into "builtin 'error' failed: …"). *)
      Primitives.current_env_ref := env;
      k (f args)

  | _ ->
      failwith (Printf.sprintf "not a function: %s" (string_of_value fn))


(* Trampoline force: uses a local work queue to process thunk chains
   without growing the OCaml stack.  Only entered when [force_depth]
   exceeds [max_force_depth].  Part of the mutual-recursion block
   so it can reference [eval] and [force]. *)
and trampoline_force (v : value) : value =
  let queue = Queue.create () in
  Queue.add v queue;
  let rec loop () =
    match Queue.take_opt queue with
    | None -> failwith "trampoline: empty queue"
    | Some v ->
        begin match v with
        | VThunk t ->
            begin match t.thunk_status with
            | Evaluated result -> Queue.add result queue; loop ()
            | Evaluating -> failwith "infinite recursion detected (trampoline)"
            | Unevaluated ->
                if t.thunk_persist then begin
                  let h = node_key_of t in
                  let run () =
                    match t.vm_code with
                    | Some (bc, code_offset, frames) ->
                        !Primitives.vm_run_thunk_ref bc code_offset frames
                    | None ->
                        let saved = !force_depth in
                        force_depth := 0;
                        let r = eval t.thunk_expr t.thunk_env in
                        force_depth := saved;
                        r
                  in
                  let result = force_node ~key:h ~run t in
                  Queue.add result queue;
                  loop ()
                end
                else begin
                  (* ephemeral thunk — no store check *)
                  t.thunk_status <- Evaluating;
                  let result =
                    match t.vm_code with
                    | Some (bc, code_offset, frames) ->
                        !Primitives.vm_run_thunk_ref bc code_offset frames
                    | None ->
                        let saved = !force_depth in
                        force_depth := 0;
                        let r = eval t.thunk_expr t.thunk_env in
                        force_depth := saved;
                        r
                  in
                  (match t.type_ann with
                   | Some ty -> check_type result ty t.thunk_loc
                   | None -> ());
                  t.thunk_status <- Evaluated result;
                  Queue.add result queue;
                  loop ()
                end
            end
        | _ -> v  (* non-thunk: done *)
        end
  in
  loop ()
(* ---- Effect System ---- *)

and perform_effect (name : string) (args : value list) : value =
  (* LAW 26: WHICH handler intercepts this effect (or that none does — the
     builtin) is an observation of ambient state; inside a node it is recorded
     as a `handler:<effect>` trace cell so a hit under a different handler
     (mock vs real) re-computes instead of cross-contaminating. *)
  Runtime.record_handler_observation name;
  (* Check for handler *)
  let rec find_handler = function
    | [] ->
        (* No handler — try builtin effect *)
        perform_builtin_effect name args
    | (n, handler, _) :: rest ->
        if n = name then handler args
        else find_handler rest
  in
  find_handler !handler_stack

and perform_builtin_effect (name : string) (args : value list) : value =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           (* Node-local sandbox scratch reads are capability-free and
              unrecorded (LAW 18) — scratch is the node's working memory.
              Outside a sandbox: an fs-read grant returns plain data (Q11
              CAS-ingested, pinned for the run), a CapSecret-only grant
              returns VSealed (M4); see Process.read_dispatch. *)
           Process.read_dispatch ~tag:"read-file"
             ~cap_err:(fun p -> "read-file: capability error: no read access for " ^ p) path
       | _ -> failwith "read-file expects a string path")

  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           (* LAW 18: inside a node, relative ⇒ sandbox scratch, absolute ⇒
              error; scripting tier unchanged (Process.write_file_effect). *)
           Process.write_file_effect ~has_cap:has_fs_write path content
       | _ -> failwith "write-file expects path and content strings")

  | "run" ->
      (* D13: process execution — capability-gated, trace-recorded, sandboxed
         (process.ml). *)
      Process.run_effect args

  | "run-dep" ->
      (* Q2 refinement: run + depfile → precise cells, no coarse tree cells. *)
      Process.run_dep_effect args

  | "http-get" ->
      (match args with
       | [VString url] -> Process.http_request ~method_:"GET" ~url ~body:None
       | _ -> failwith "http-get expects a url string")

  | "http-post" ->
      (match args with
       | [VString url; VString body] ->
           Process.http_request ~method_:"POST" ~url ~body:(Some body)
       | _ -> failwith "http-post expects a url string and a body string")

  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg;
           VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg;
           VNil
       | _ -> failwith "log expects a message string")

  (* ---- Q13 domain primitives (PLAN-m4-cells.md; src/domain_prims.ml) ---- *)

  | "tree-observe" ->
      (match args with
       | [VString root] -> Domain_prims.tree_observe root
       | _ -> failwith "tree-observe expects a root path string")

  | "materialize-file" ->
      (match args with
       | [VString path; VString content] ->
           Domain_prims.materialize_file path content false; VNil
       | [VString path; VString content; VKeyword "executable"] ->
           Domain_prims.materialize_file path content true; VNil
       | _ -> failwith "materialize-file expects a path, content, and optional :executable"
      )

  | "remove-file" ->
      (match args with
       | [VString path] -> Domain_prims.remove_file path; VNil
       | _ -> failwith "remove-file expects a path string")

  | "proc-spawn" ->
      (match args with
       | [spec] -> Domain_prims.proc_spawn spec
       | _ -> failwith "proc-spawn expects a spec map")

  | "proc-alive?" ->
      (match args with
       | [VInt pid] -> VBool (Domain_prims.proc_alive pid)
       | _ -> failwith "proc-alive? expects a pid integer")

  | "proc-stop" ->
      (match args with
       | [VString name; VInt pid] -> Domain_prims.proc_stop name pid; VNil
       | _ -> failwith "proc-stop expects a service name and a pid integer")

  | "proc-reap" ->
      (match args with
       | [] -> Domain_prims.proc_reap (); VNil
       | _ -> failwith "proc-reap takes no arguments")

  | "domain-state-get" ->
      (match args with
       | [VString key] -> Domain_prims.domain_state_get key
       | _ -> failwith "domain-state-get expects a key string")

  | "domain-state-put" ->
      (match args with
       | [VString key; v] -> Domain_prims.domain_state_put key v; VNil
       | _ -> failwith "domain-state-put expects a key string and a value")

  | _ ->
      failwith ("unhandled effect: " ^ name)

(* ---- Helpers ---- *)

and has_fs_read (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_read cap path) !current_capabilities

and has_fs_write (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_write cap path) !current_capabilities


(* (load-module "file.pp"): evaluate the file against a fresh initial env and
   package the bindings it added as a module value. Shared by the tail
   evaluator and EDo. *)
and eval_module_file (path : string) : value =
  let source = Runtime.loader_read path in
  let exprs = !Primitives.expand_toplevel_ref (Reader.read_string source) in
  let mod_ref = ref (Primitives.initial_env ()) in
  ignore (eval_expressions exprs mod_ref);
  VEnvMap (new_bindings ~base:(Primitives.initial_env ()).bindings (!mod_ref).bindings)

(* Evaluate expressions sequentially with mutable env — used by ELoad, ELoadModule, and REPL.
   `exprs` is always a list of top-level-shaped forms straight out of
   Reader.read_string (the top-level file/REPL driver, or a `load`ed file's
   own top-level forms), so every element is individually `ELocated`. *)
and eval_expressions (exprs : expr list) (env : env ref) : value =
  let unwrap e = match e with ELocated (_, e') -> e' | _ -> e in
  (* Evaluate ONE form, mutating `env` for defs/imports; wrapped in ITS OWN
     location (LAW 29/D12): an error escaping this form is decorated with
     this form's file:line before it can unwind past a `load` that brought
     it in — never doubled if a deeper form already located it. *)
  let step (e : expr) : value =
    Runtime.with_form_location e (fun () ->
      match unwrap e with
      | EDef (name, params, body) ->
          let closure = make_closure ~name:(Some name) params body env in
          env := extend_env !env name closure;
          closure
      | EDefNode (name, params, body) ->
          let closure = make_closure ~name:(Some name) params body env in
          env := extend_env !env name closure;
          closure
      | EDefValue (name, rhs) ->
          (* Top level is sequential: the RHS is evaluated now (a forward
             reference is an unbound-symbol error), the value bound. *)
          let v = eval rhs !env in
          env := extend_env !env name v;
          v
      | EImport _ ->
          let mod_val = force (eval e !env) in
          (match mod_val with
           | VEnvMap bindings ->
               env := List.fold_left (fun env' (n, v) ->
                 extend_env env' n v) !env bindings;
               mod_val
           | _ -> failwith "import expects a module value")
      | ELoad path ->
          (* `~source:path`: the loaded file's OWN path (not the reader's
             "<?>" default), so ITS forms are in turn correctly located.
             M3 defmacro: shared expansion hook, same as every other
             Reader.read_string call site. *)
          let contents = Runtime.loader_read path in
          let sub_exprs = !Primitives.expand_toplevel_ref
                            (Reader.read_string ~source:path contents) in
          eval_expressions sub_exprs env
      | _ ->
          let result = force (eval e !env) in
          (match result with
           | VEnvMap bindings ->
               env := List.fold_left (fun env' (n, v) ->
                 extend_env env' n v) !env bindings;
               result
           | _ -> result))
  in
  let rec go = function
    | [] -> VNil
    | [e] -> step e
    | e :: rest -> ignore (step e); go rest
  in
  go exprs

(* ---- Public API ---- *)

(* Evaluate an expression in the initial environment *)
let eval_program (e : expr) : value =
  let env = Primitives.initial_env () in
  eval e env

(* Evaluate and force (for top-level expressions) *)
let eval_and_force (e : expr) : value =
  force (eval_program e)

(* Initialize the evaluator state *)
let init () =
  handler_stack := [];
  current_capabilities := !initial_capabilities;
  if not !Runtime.keep_thunks then Hashtbl.clear thunk_store;
  (* M4 probes: the registry is script-tier registration state, re-established
     by the program's own top-level `(register-probe ...)` forms on every
     fresh evaluation — reset it here unconditionally (like the macro table
     below), never gated on keep_thunks: a --watch pass always re-executes
     the whole program's top level, so stale entries from a prior pass must
     not survive into one that no longer registers them. Pinned per-pass
     results (Runtime.probe_values) are a separate lifetime, cleared at the
     three points main.ml's watch loop clears Store.run_pins. *)
  Hashtbl.reset Runtime.domain_registry;
  (* M3 defmacro: reset the macro table AND the gensym counter at the start
     of every fresh run — the counter matters for LAW 20 stability (a
     gensym'd name can be baked into an expanded node's code, so re-running
     the SAME source must reproduce the SAME counter sequence, or the same
     program could hash differently run to run). Unconditional (not gated
     on Runtime.keep_thunks like thunk_store): both are derived fresh from
     source text each run, never persistent cache state. *)
  !Primitives.macro_reset_ref ();
  Primitives.gensym_counter := 0;
  Primitives.set_force force;
  Primitives.set_eval eval;
  Primitives.set_apply apply;
  (* Phase 3: let Primitives' scheduler-aware force-deep compute tree-walker
     node keys and run node bodies without a dependency cycle (Primitives is
     compiled before Evaluator). *)
  Primitives.node_key_of_ref := node_key_of;
  Primitives.run_node_body_ref := (fun ~key ~run t -> run_node_body ~key ~run t);
  Primitives.resolve_if_hit_ref := (fun t key ->
    (* Same node_caps-gated authority as force_node (M3 LAW 23b) — this is
       the force-deep collect pass's own pre-check of the same key. *)
    match Store.hit ~key ~authorized:(cell_authorized_for t.node_caps) with
    | Store.HitOk v -> t.thunk_status <- Evaluated v; true
    | Store.HitFailed _ -> true (* known outcome; the ordinary force path re-raises it *)
    | Store.Miss -> false);
  (* Config values may be unforced thunks; their trace-cell observation (LAW 33)
     hashes the forced value, both at record time and at hit re-observation. *)
  Runtime.force_hook := force
