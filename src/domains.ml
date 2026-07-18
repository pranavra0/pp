(* pp generic domain orchestration — a domain is an observe/diff/apply
   triple of ordinary pp functions running under core-enforced discipline.

   Everything TRUSTED about running a registered write-domain lives here:
   the journal bracket, the observed_all suspension, cap threading into
   observe/apply, plan caching, and verify-after-write. Nothing here knows
   what "create" or "start" means — that policy is the domain's own diff/
   apply closures (stdlib/domain-fs.pp, stdlib/domain-proc.pp, or a
   third-party domain registered via `register-domain`). This is what
   replaced src/reconciler.ml and src/supervisor.ml.

   A domain's plan (the value its `diff` returns) is a map with two keys
   this module inspects and nothing else:
     :items    a list or vector of opaque per-item values — `apply`
               interprets them; core only checks non-emptiness
               (verify-after-write).
     :summary  an ORDERED VECTOR of [key value] string pairs the domain
               itself assembled (its own :kind tally, e.g. [[:root R]
               [:create "2"] [:update "0"] [:delete "0"]] for fs,
               [[:started "2"] ...] for proc) — core echoes this VERBATIM
               into the journal intent line and the per-pass stderr
               summary, so the domain (not core) decides vocabulary,
               order, and zero-defaults; core's job is purely mechanical
               formatting, which is what makes the SAME code path
               reproduce the old fs-only "root=R create=C update=U
               delete=D" journal/print bytes and a totally different
               third-party domain's own vocabulary. A VECTOR, not a map:
               plan caching round-trips a MISS's result through the store
               (Codec), which canonicalizes a VMap's entry order (sorted
               by encoded key, codec.ml) but preserves a VVector's — a
               cache HIT reproducing the summary in a different field
               order than the original computation would silently break
               the byte-compatibility this format exists for. *)

open Core_model

let force value =
  Session.force (Effect.perform Dynamic_scope.Get_session) value

let find_kv kvs key = Force_deep.find_kv ~force kvs key

let plan_map (plan : value) : (value * value) list =
  match force plan with
  | VMap kvs -> kvs
  | other -> failwith ("domain diff: plan must be a map with :items and :summary, got "
                       ^ Presentation.string_of_value other)

(* :items may be an ordinary pp LIST (cons/nil — the natural shape
   map/filter/append produce, what domain-fs.pp/domain-proc.pp use) or a
   vector; core only ever needs to know whether there's anything left
   un-converged (verify-after-write), never to walk the items itself —
   `apply` is the only thing that interprets them, in pp. *)
let plan_items_empty (plan : value) : bool =
  match find_kv (plan_map plan) "items" with
  | None | Some VNil -> true
  | Some (VVector arr) -> Array.length arr = 0
  | Some (VPair _) -> false
  | Some other -> failwith ("domain diff: plan :items must be a list or vector, got " ^ Presentation.string_of_value other)

let summary_pair (entry : value) : string * string =
  let two_of arr =
    if Array.length arr <> 2 then
      failwith "domain diff: :summary entries must be 2-element [key value] pairs"
    else (arr.(0), arr.(1))
  in
  let (k, v) = match force entry with
    | VVector arr -> two_of arr
    | VPair (a, VPair (b, VNil)) -> (a, b)
    | other -> failwith ("domain diff: :summary entries must be [key value] pairs, got "
                         ^ Presentation.string_of_value other)
  in
  let ks = match Presentation.string_like (force k) with Some s -> s | None -> failwith ("domain diff: :summary key must be a string, got " ^ Presentation.string_of_value k) in
  let vs = match force v with
    | VString s -> s
    | other -> failwith ("domain diff: :summary value must be a string, got " ^ Presentation.string_of_value other) in
  (ks, vs)

let plan_summary (plan : value) : (string * string) list =
  match find_kv (plan_map plan) "summary" with
  | Some (VVector arr) -> Array.to_list (Array.map summary_pair arr)
  | Some (VPair _ as lst) ->
      let rec collect = function
        | VNil -> []
        | VPair (a, d) -> summary_pair a :: collect (force d)
        | other -> failwith ("domain diff: :summary must be a list/vector of pairs, got "
                             ^ Presentation.string_of_value other)
      in collect lst
  | Some VNil | None -> []
  | Some other -> failwith ("domain diff: :summary must be a list/vector of [key value] pairs, got "
                            ^ Presentation.string_of_value other)

(* ---- Plan caching (falls out of the existing store, no new mechanism) ----

   key = H("domain-plan", diff-code-hash, observed-hash, desired-hash).
   diff runs under EMPTY caps (purity), so every world-read it could
   possibly make is already accounted for by observed/desired — the key
   captures the WHOLE identity, so a TRACE-LESS store entry (reads = [])
   is sound: cache policy treats an empty reads list as vacuously
   `Usable forever, so a hit here means exactly "same key ⇒ same plan",
   which is exactly what a pure function's cache should mean. Wiring a
   synthetic `(node ...)` AST here (the alternative of routing this through
   the ordinary node-caching machinery)
   would need a fabricated thunk/env solely to get a key and a store slot
   direct cache-policy and repository calls already provide
   free, with no AST to keep in sync with a node body that doesn't exist —
   the direct route is documented here as the deliberate, simpler choice. *)
let plan_cache_key ~(diff_closure : value) ~(observed : value) ~(desired : value) : string =
  let diff_hash = Identity.hash_value diff_closure in
  let observed_hash = Identity.hash_value (Primitives.force_deep observed) in
  let desired_hash = Identity.hash_value (Primitives.force_deep desired) in
  Hasher.hash_concat ["domain-plan"; diff_hash; observed_hash; desired_hash]

let compute_plan ~(domain_name : string) ~(diff_closure : value)
    ~(observed : value) ~(desired : value) : value =
  let key = Identity_types.Cache_key.of_digest
    (plan_cache_key ~diff_closure ~observed ~desired) in
  match Cache_policy.lookup Cache_policy.default ~key ~authorized:(fun _ -> true) with
  | Cache_policy.HitOk v ->
      Cache_policy.diagnose Cache_policy.default "domain %s: plan %s: hit (cached, unchanged observed/desired)"
        domain_name (Cache_policy.short_key (Identity_types.Cache_key.to_string key));
      v
  | Cache_policy.HitFailed _ | Cache_policy.Miss ->
      Cache_policy.diagnose Cache_policy.default "domain %s: plan %s: miss — running diff"
        domain_name (Cache_policy.short_key (Identity_types.Cache_key.to_string key));
      let plan =
        try Primitives.call_with_args diff_closure [observed; desired]
        with effect Dynamic_scope.Get_capabilities, k -> Effect.Deep.continue k []
      in
      let result_hash = Identity_types.Object_hash.of_digest (Identity.hash_value plan) in
      (try Object_repository.put Object_repository.default
             ~key:(Identity_types.Object_hash.to_string result_hash) ~value:plan with _ -> ());
      (try Trace_repository.put Trace_repository.default ~key ~outcome:Trace_repository.Ok ~result_hash ~reads:[] with _ -> ());
      plan

(* ---- Stratification (LAW 30 full form) ----
   After root evaluation, reject if any recorded cell falls under a
   registered write-domain's own namespace prefixes — generalized from the
   old hardwired-to-fs/proc checks in reconciler.ml/supervisor.ml. *)
let has_prefix ~(prefix : string) (s : string) : bool =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let stratification_check session (write_domains : (string * Session.domain_entry) list) : unit =
  List.iter (fun (cell, _) ->
    List.iter (fun (name, entry) ->
      if List.exists (fun prefix -> has_prefix ~prefix cell) entry.Session.dm_namespace then
        failwith (Printf.sprintf
          "reconcile: stratification violation (LAW 30): the desired state for \
           domain '%s' observed its own domain: %s" name cell))
      write_domains)
    (Session.observations session)

(* ---- Per-domain pass ----
   observe fresh (never cached) under the domain's own cap; diff cached and
   pure; apply under the SAME cap (a write grant already covers read at its
   own scope — no separate read-cap threading needed); journal a generic
   intent/done bracket; verify-after-write by re-observing and re-diffing. *)
let with_domain (name : string) (cap : Capability.t) (f : unit -> 'a) : 'a =
  Dynamic_scope.with_domain name (fun () ->
    Dynamic_scope.with_capabilities [cap] f)

(* A load-bearing wall (found the hard way): observe (and, to be
   safe across --watch --stabilize's keep_thunks, apply) is a call to a
   FIXED closure with NO varying arguments — a 0-ary observe, or an apply
   whose closure/env never changes between a pass's own two calls that
   matter (this one and the verify re-observe). pp's ordinary content-
   addressed `let`-thunk memoization (Evaluator.make_thunk_ca) keys on
   (expr, env_hash, caps_hash, cfg_hash, handlers_hash) — with an unchanged
   closure env and an unchanged ambient (the SAME dm_cap both times,
   with_domain), that key is IDENTICAL across the two calls a single pass
   makes, so the SECOND call silently replayed the FIRST call's memoized
   `perform` results (a `perform domain-state-get`/`tree-observe` never
   re-ran) instead of re-observing reality — exactly the staleness "fresh
   every pass, never cached" was written to rule out, just via a mechanism
   one layer further down than the plan cache. Fix: push a fresh, unique
   config-stack layer before each call — invisible to any real `(config
   ...)` read (a key no program would query) but folded into
   make_thunk_ca's cfg_hash, so every call gets a distinct key and can
   never hit an in-memory thunk from a sibling call. *)
let fresh_nonce_config () : value =
  let n = Session.next_cache_bust (Effect.perform Dynamic_scope.Get_session) in
  VMap [(VString "__pp_q13_cache_bust", VInt n)]
let call_uncached (fn : value) (args : value list) : value =
  Dynamic_scope.with_config (fresh_nonce_config ()) (fun () ->
    Primitives.call_with_args fn args)

let observe_domain (entry : Session.domain_entry) (name : string) : value =
  with_domain name entry.Session.dm_cap
    (fun () -> call_uncached entry.Session.dm_observe [])

let verify_failed_msg (name : string) : string =
  "reconcile: verify-after-write failed for domain " ^ name
let run_domain ~(name : string) ~(entry : Session.domain_entry) ~(desired : value) : unit =
  let diff_closure = match entry.Session.dm_diff with
    | Some d -> d
    | None -> assert false (* filtered out by run_all before this is called *)
  in
  let apply_closure = match entry.Session.dm_apply with
    | Some a -> a
    | None -> assert false
  in
  (* Load-bearing suspension: a domain's own bookkeeping
     during observe/diff/apply must never trip its own stratification scan. *)
  Dynamic_scope.without_observation_collection (fun () ->
    let observed = observe_domain entry name in
    let plan = compute_plan ~domain_name:name ~diff_closure ~observed ~desired in
    let summary = plan_summary plan in
    let hash = Hasher.hash_concat
        ["domain-pass"; name; Identity.hash_value (Primitives.force_deep desired)] in
    Journal.append (Journal.DomainIntent { hash; fields = summary });
    with_domain name entry.Session.dm_cap
      (fun () -> ignore (call_uncached apply_closure [plan]));
    Journal.append (Journal.DomainDone { hash });
    Printf.eprintf "[reconcile:%s] %s\n%!" name
      (String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) summary));
    (* Verify-after-write: re-observe, re-diff (the SAME cached-diff
       machinery) against desired; non-empty items = hard error. Whole-
       domain, deliberately stronger than a per-file inline check. *)
    let observed2 = observe_domain entry name in
    let plan2 = compute_plan ~domain_name:name ~diff_closure ~observed:observed2 ~desired in
    if not (plan_items_empty plan2) then
      failwith (verify_failed_msg name)
  )

(* ---- Driver entry point ----
   [all_desired] is a map of domain-name -> desired-state value (main.ml
   builds this for --reconcile/--supervise's auto-wiring; a program calling
   register-domain itself simply returns this shape directly, N domains,
   one evaluation). Every name must resolve to a registered WRITE domain
   (a probe named here is a hard error, not silently skipped). *)
(* Recorded ONCE per
   SUCCESSFUL pass (after every domain's run_domain has completed without
   raising) — [forced] is the exact fully-forced {domain -> desired} (or,
   under host-qualified distribution, {host -> {domain -> desired}}) value
   this pass converged, already computed by [run_all] below (reused, not
   re-forced). Stores it as an ordinary content-addressed object (so
   `pp gc`'s replay subprocess, which re-derives the identical value, can
   cross-check its own hash against this one) and appends BOTH the frozen
   journal Epoch line (audit trail) and the Gcroots manifest entry (the
   replayable "how" — see gcroots.ml). Best-effort: a failure to persist
   the epoch must never fail an otherwise-successful reconcile pass. *)
let record_epoch invocation (forced : value) : unit =
  try
    let hash = Identity.hash_value forced in
    (try Object_repository.put Object_repository.default ~key:hash ~value:forced with _ -> ());
    Journal.append (Journal.Epoch { hash });
    Gcroots.record ~keep:(Invocation.gc_keep_epochs invocation)
      { Gcroots.gr_hash = hash;
        gr_grants = Invocation.initial_grant_specs invocation;
        gr_files = Invocation.program_files invocation;
        gr_reconcile_root = Invocation.program_reconcile_root invocation;
        gr_supervise = Invocation.program_supervise invocation;
        gr_member_name = Invocation.program_member_name invocation;
        gr_desired_object = Invocation.program_desired_object invocation }
  with _ -> ()

let run_all invocation (all_desired : value) : unit =
  let session = Effect.perform Dynamic_scope.Get_session in
  let forced = Primitives.force_deep all_desired in
  let entries = match forced with
    | VMap kvs -> kvs
    | other ->
        failwith ("reconcile: the program must return a map of domain-name to \
                   desired-state, got " ^ Presentation.string_of_value other)
  in
  let resolved = List.map (fun (k, desired) ->
    let name = match k with
      | VString s | VKeyword s -> s
      | other -> failwith ("reconcile: domain name must be a string or keyword, got "
                           ^ Presentation.string_of_value other)
    in
    match Session.find_domain session name with
    | None -> failwith ("reconcile: no domain registered under name '" ^ name ^ "'")
    | Some entry ->
        (match entry.Session.dm_diff, entry.Session.dm_apply with
         | Some _, Some _ -> (name, entry, desired)
         | _ -> failwith ("reconcile: domain '" ^ name
                          ^ "' has no :diff/:apply (it is a probe, not a write-domain)")))
    entries
  in
  let write_domains = List.map (fun (n, e, _) -> (n, e)) resolved in
  stratification_check session write_domains;
  List.iter (fun (name, entry, desired) -> run_domain ~name ~entry ~desired) resolved;
  record_epoch invocation forced

(* Whether at least one registered domain can actually be converged — used
   by main.ml to decide whether a bare register-domain-only program (no
   --reconcile/--supervise flag) should still run the generic pass. *)
let any_write_domain_registered () : bool =
  Session.fold_domains (Effect.perform Dynamic_scope.Get_session) (fun _ entry acc ->
    acc || (entry.Session.dm_diff <> None && entry.Session.dm_apply <> None))
    false
