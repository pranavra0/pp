open Pp_kernel
(* Generic domain orchestration. A domain supplies observe, diff, apply, and
   optional verification functions. This module owns the journal bracket,
   capability threading, plan cache, and verify-after-write step. Domain
   policy stays in pp source. *)

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
  let observed_hash = Identity.hash_value (Force_deep.force_deep observed) in
  let desired_hash = Identity.hash_value (Force_deep.force_deep desired) in
  Hasher.hash_concat ["domain-plan"; diff_hash; observed_hash; desired_hash]

let compute_plan ~(domain_name : string) ~(diff_closure : value)
    ~(observed : value) ~(desired : value) : value =
  let session = Effect.perform Dynamic_scope.Get_session in
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
        try Session.call session ~env:Environment.empty diff_closure [observed; desired]
        with effect Dynamic_scope.Get_capabilities, k -> Effect.Deep.continue k []
      in
      let result_hash = Identity_types.Object_hash.of_digest (Identity.hash_value plan) in
      (try Object_repository.put Object_repository.default
             ~key:(Identity_types.Object_hash.to_string result_hash) ~value:plan
       with Sys_error _ | Unix.Unix_error _ -> ());
      (try Trace_repository.put Trace_repository.default ~key
             ~outcome:Trace_repository.Ok ~result_hash ~reads:[]
       with Sys_error _ | Unix.Unix_error _ -> ());
      plan

(* ---- Stratification ----
   Reject a read from a domain's own write namespace. *)
let has_prefix ~(prefix : string) (s : string) : bool =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

type target = {
  name : string;
  entry : Session.domain_entry;
  desired : value;
}

type observed = {
  target : target;
  state : value;
}

type planned = {
  observed : observed;
  plan : value;
  summary : (string * string) list;
}

type pass = {
  invocation : Invocation.t;
  forced_desired : value;
  targets : target list;
}

let stratification_check session (write_domains : target list) : unit =
  List.iter (fun (cell, _) ->
    List.iter (fun target ->
      if List.exists (fun prefix -> has_prefix ~prefix cell) target.entry.Session.dm_namespace then
        failwith (Printf.sprintf
          "reconcile: stratification violation (LAW 30): the desired state for \
           domain '%s' observed its own domain: %s" target.name cell))
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
   observations instead of re-observing reality. Push a fresh, unique
   config-stack layer before each call. It is invisible to real config reads
   but changes make_thunk_ca's config hash, preventing sibling calls from
   sharing an in-memory thunk. *)
let fresh_nonce_config () : value =
  let n = Session.next_cache_bust (Effect.perform Dynamic_scope.Get_session) in
  Value.map [(VString "__pp_q13_cache_bust", VInt n)]
let call_uncached (fn : value) (args : value list) : value =
  Dynamic_scope.with_config (fresh_nonce_config ()) (fun () ->
    Session.call (Effect.perform Dynamic_scope.Get_session)
      ~env:Environment.empty fn args)

let observe_domain (entry : Session.domain_entry) (name : string) : value =
  with_domain name entry.Session.dm_cap
    (fun () -> call_uncached entry.Session.dm_observe [])

let verify_failed_msg (name : string) : string =
  "reconcile: verify-after-write failed for domain " ^ name

let observe_target (target : target) : observed =
  { target; state = observe_domain target.entry target.name }

let diff_target (observed : observed) : planned =
  let target = observed.target in
  let diff_closure = match target.entry.Session.dm_diff with
    | Some d -> d
    | None -> assert false (* filtered out when the pass is prepared *)
  in
  let plan = compute_plan ~domain_name:target.name ~diff_closure
      ~observed:observed.state ~desired:target.desired in
  { observed; plan; summary = plan_summary plan }

let apply_target (planned : planned) : unit =
  let target = planned.observed.target in
  let apply_closure = match target.entry.Session.dm_apply with
    | Some a -> a
    | None -> assert false (* filtered out when the pass is prepared *)
  in
  let hash = Hasher.hash_concat
      ["domain-pass"; target.name;
       Identity.hash_value (Force_deep.force_deep target.desired)] in
  Journal.append (Journal.DomainIntent { hash; fields = planned.summary });
  with_domain target.name target.entry.Session.dm_cap
    (fun () -> ignore (call_uncached apply_closure [planned.plan]));
  Journal.append (Journal.DomainDone { hash });
  Printf.eprintf "[reconcile:%s] %s\n%!" target.name
    (String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ v) planned.summary))

let verify_target (planned : planned) : unit =
  let target = planned.observed.target in
  let observed2 = observe_target target in
  let planned2 = diff_target observed2 in
  if not (plan_items_empty planned2.plan) then
    failwith (verify_failed_msg target.name)

let run_target (target : target) : unit =
  (* Load-bearing suspension: a domain's own bookkeeping
     during observe/diff/apply must never trip its own stratification scan. *)
  Dynamic_scope.without_observation_collection (fun () ->
    let planned = diff_target (observe_target target) in
    apply_target planned;
    verify_target planned
  )

(* Resolve and stratify the desired state before any domain can mutate the
   world. The returned pass is the immutable input to the staged driver. *)
let prepare_pass invocation (all_desired : value) : pass =
  let session = Effect.perform Dynamic_scope.Get_session in
  let forced_desired = Force_deep.force_deep all_desired in
  let entries = match forced_desired with
    | VMap kvs -> kvs
    | other ->
        failwith ("reconcile: the program must return a map of domain-name to " ^
                  "desired-state, got " ^ Presentation.string_of_value other)
  in
  let targets = List.map (fun (k, desired) ->
    let name = match k with
      | VString s | VKeyword s -> s
      | other -> failwith ("reconcile: domain name must be a string or keyword, got "
                           ^ Presentation.string_of_value other)
    in
    match Session.find_domain session name with
    | None -> failwith ("reconcile: no domain registered under name '" ^ name ^ "'")
    | Some entry ->
        (match entry.Session.dm_diff, entry.Session.dm_apply with
         | Some _, Some _ -> { name; entry; desired }
         | _ -> failwith ("reconcile: domain '" ^ name
                          ^ "' has no :diff/:apply (it is a probe, not a write-domain)")))
    entries
  in
  stratification_check session targets;
  { invocation; forced_desired; targets }

(* Record the converged desired object and the node keys forced to derive it.
   Together they root the durable trace graph. *)
let record_epoch invocation (forced : value) : unit =
  try
    let hash = Identity.hash_value forced in
    (try Object_repository.put Object_repository.default ~key:hash ~value:forced
     with Sys_error _ | Unix.Unix_error _ -> ());
    Journal.append (Journal.Epoch { hash });
    Gcroots.record ~keep:(Invocation.gc_keep_epochs invocation)
      { Gcroots.gr_hash = hash;
        gr_nodes =
          Session.wanted_nodes (Effect.perform Dynamic_scope.Get_session) }
  with Sys_error _ | Unix.Unix_error _ -> ()

let run_pass (pass : pass) : unit =
  List.iter run_target pass.targets;
  record_epoch pass.invocation pass.forced_desired

(* Whether at least one registered domain can actually be converged — used
   by command_reconcile.ml to decide whether a bare register-domain!-only program (no
   --reconcile/--supervise flag) should still run the generic pass. *)
let any_write_domain_registered () : bool =
  Session.fold_domains (Effect.perform Dynamic_scope.Get_session) (fun _ entry acc ->
    acc || (entry.Session.dm_diff <> None && entry.Session.dm_apply <> None))
    false
