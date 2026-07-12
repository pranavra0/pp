(* pp Q13 generic domain orchestration (PLAN-m4-cells.md §Q13).

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

open Types

let find_kv (kvs : (value * value) list) (key : string) : value option =
  List.find_map (fun (k, v) ->
    match k with
    | VKeyword k' | VString k' when k' = key -> Some (!Runtime.force_hook v)
    | _ -> None)
    kvs

let plan_map (plan : value) : (value * value) list =
  match !Runtime.force_hook plan with
  | VMap kvs -> kvs
  | other -> failwith ("domain diff: plan must be a map with :items and :summary, got "
                       ^ string_of_value other)

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
  | Some other -> failwith ("domain diff: plan :items must be a list or vector, got " ^ string_of_value other)

let summary_pair (entry : value) : string * string =
  let two_of arr =
    if Array.length arr <> 2 then
      failwith "domain diff: :summary entries must be 2-element [key value] pairs"
    else (arr.(0), arr.(1))
  in
  let (k, v) = match !Runtime.force_hook entry with
    | VVector arr -> two_of arr
    | VPair (a, VPair (b, VNil)) -> (a, b)
    | other -> failwith ("domain diff: :summary entries must be [key value] pairs, got "
                         ^ string_of_value other)
  in
  let ks = match !Runtime.force_hook k with
    | VString s | VKeyword s -> s
    | other -> failwith ("domain diff: :summary key must be a string, got " ^ string_of_value other) in
  let vs = match !Runtime.force_hook v with
    | VString s -> s
    | other -> failwith ("domain diff: :summary value must be a string, got " ^ string_of_value other) in
  (ks, vs)

let plan_summary (plan : value) : (string * string) list =
  match find_kv (plan_map plan) "summary" with
  | Some (VVector arr) -> Array.to_list (Array.map summary_pair arr)
  | Some (VPair _ as lst) ->
      let rec collect = function
        | VNil -> []
        | VPair (a, d) -> summary_pair a :: collect (!Runtime.force_hook d)
        | other -> failwith ("domain diff: :summary must be a list/vector of pairs, got "
                             ^ string_of_value other)
      in collect lst
  | Some VNil | None -> []
  | Some other -> failwith ("domain diff: :summary must be a list/vector of [key value] pairs, got "
                            ^ string_of_value other)

(* ---- Plan caching (Q4's "plans cache", falling out of the existing store) ----

   key = H("domain-plan", diff-code-hash, observed-hash, desired-hash).
   diff runs under EMPTY caps (purity), so every world-read it could
   possibly make is already accounted for by observed/desired — the key
   captures the WHOLE identity, so a TRACE-LESS store entry (reads = [])
   is sound: Store.hit's classify treats an empty reads list as vacuously
   `Usable forever, so a hit here means exactly "same key ⇒ same plan",
   which is exactly what a pure function's cache should mean. Wiring a
   synthetic `(node ...)` AST here (the alternative the contract offers)
   would need a fabricated thunk/env solely to get a key and a store slot
   this direct Store.hit/store_object/store_trace path already gives for
   free, with no AST to keep in sync with a node body that doesn't exist —
   the direct route is documented here as the deliberate, simpler choice. *)
let plan_cache_key ~(diff_closure : value) ~(observed : value) ~(desired : value) : string =
  let diff_hash = Hasher.hash_value diff_closure in
  let observed_hash = Hasher.hash_value (Primitives.force_deep observed) in
  let desired_hash = Hasher.hash_value (Primitives.force_deep desired) in
  Hasher.hash_concat ["domain-plan"; diff_hash; observed_hash; desired_hash]

let compute_plan ~(domain_name : string) ~(diff_closure : value)
    ~(observed : value) ~(desired : value) : value =
  let key = plan_cache_key ~diff_closure ~observed ~desired in
  match Store.hit ~key ~authorized:(fun _ -> true) with
  | Store.HitOk v ->
      Store.why "domain %s: plan %s: hit (cached, unchanged observed/desired)"
        domain_name (Store.short_key key);
      v
  | Store.HitFailed _ | Store.Miss ->
      Store.why "domain %s: plan %s: miss — running diff" domain_name (Store.short_key key);
      let plan =
        Runtime.with_ref Runtime.current_capabilities []
          (fun () -> Primitives.call_with_args diff_closure [observed; desired])
      in
      let result_hash = Hasher.hash_value plan in
      (try Store.store_object ~key:result_hash ~value:plan with _ -> ());
      (try Store.store_trace ~key ~outcome:Store.Ok ~result_hash ~reads:[] with _ -> ());
      plan

(* ---- Stratification (LAW 30 full form) ----
   After root evaluation, reject if any recorded cell falls under a
   registered write-domain's own namespace prefixes — generalized from the
   old hardwired-to-fs/proc checks in reconciler.ml/supervisor.ml. *)
let has_prefix ~(prefix : string) (s : string) : bool =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let stratification_check (write_domains : (string * Runtime.domain_entry) list) : unit =
  List.iter (fun (cell, _) ->
    List.iter (fun (name, entry) ->
      if List.exists (fun prefix -> has_prefix ~prefix cell) entry.Runtime.dm_namespace then
        failwith (Printf.sprintf
          "reconcile: stratification violation (LAW 30): the desired state for \
           domain '%s' observed its own domain: %s" name cell))
      write_domains)
    !Runtime.observed_all

(* ---- Per-domain pass ----
   observe fresh (never cached) under the domain's own cap; diff cached and
   pure; apply under the SAME cap (a write grant already covers read at its
   own scope — no separate read-cap threading needed); journal a generic
   intent/done bracket; verify-after-write by re-observing and re-diffing. *)
let with_domain (name : string) (cap : capability) (f : unit -> 'a) : 'a =
  Runtime.with_ref Runtime.current_domain (Some name) (fun () ->
    Runtime.with_ref Runtime.current_capabilities [cap] f)

(* Q13's own load-bearing wall (found the hard way): observe (and, to be
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
let cache_bust_counter = ref 0

let fresh_nonce_config () : value =
  incr cache_bust_counter;
  VMap [(VString "__pp_q13_cache_bust", VInt !cache_bust_counter)]

let call_uncached (fn : value) (args : value list) : value =
  Runtime.with_ref Runtime.config_stack
    (fresh_nonce_config () :: !Runtime.config_stack)
    (fun () -> Primitives.call_with_args fn args)

let observe_domain (entry : Runtime.domain_entry) (name : string) : value =
  with_domain name entry.Runtime.dm_cap
    (fun () -> call_uncached entry.Runtime.dm_observe [])

let verify_failed_msg (name : string) : string =
  "reconcile: verify-after-write failed for domain " ^ name

let run_domain ~(name : string) ~(entry : Runtime.domain_entry) ~(desired : value) : unit =
  let diff_closure = match entry.Runtime.dm_diff with
    | Some d -> d
    | None -> assert false (* filtered out by run_all before this is called *)
  in
  let apply_closure = match entry.Runtime.dm_apply with
    | Some a -> a
    | None -> assert false
  in
  (* Load-bearing suspension (PLAN-m4-cells.md): a domain's own bookkeeping
     during observe/diff/apply must never trip its own stratification scan —
     exception-safe with_ref, never a hand-rolled save/restore. Does NOT
     suspend trace_stack: node caching inside a domain's fns keeps working. *)
  Runtime.with_ref Runtime.observe_all false (fun () ->
    let observed = observe_domain entry name in
    let plan = compute_plan ~domain_name:name ~diff_closure ~observed ~desired in
    let summary = plan_summary plan in
    let hash = Hasher.hash_concat
        ["domain-pass"; name; Hasher.hash_value (Primitives.force_deep desired)] in
    Journal.append (Journal.DomainIntent { hash; fields = summary });
    with_domain name entry.Runtime.dm_cap
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
      failwith (verify_failed_msg name))

(* ---- Driver entry point ----
   [all_desired] is a map of domain-name -> desired-state value (main.ml
   builds this for --reconcile/--supervise's auto-wiring; a program calling
   register-domain itself simply returns this shape directly, N domains,
   one evaluation). Every name must resolve to a registered WRITE domain
   (a probe named here is a hard error, not silently skipped). *)
let run_all (all_desired : value) : unit =
  let entries = match Primitives.force_deep all_desired with
    | VMap kvs -> kvs
    | other ->
        failwith ("reconcile: the program must return a map of domain-name to \
                   desired-state, got " ^ string_of_value other)
  in
  let resolved = List.map (fun (k, desired) ->
    let name = match k with
      | VString s | VKeyword s -> s
      | other -> failwith ("reconcile: domain name must be a string or keyword, got "
                           ^ string_of_value other)
    in
    match Hashtbl.find_opt Runtime.domain_registry name with
    | None -> failwith ("reconcile: no domain registered under name '" ^ name ^ "'")
    | Some entry ->
        (match entry.Runtime.dm_diff, entry.Runtime.dm_apply with
         | Some _, Some _ -> (name, entry, desired)
         | _ -> failwith ("reconcile: domain '" ^ name
                          ^ "' has no :diff/:apply (it is a probe, not a write-domain)")))
    entries
  in
  let write_domains = List.map (fun (n, e, _) -> (n, e)) resolved in
  stratification_check write_domains;
  List.iter (fun (name, entry, desired) -> run_domain ~name ~entry ~desired) resolved

(* Whether at least one registered domain can actually be converged — used
   by main.ml to decide whether a bare register-domain-only program (no
   --reconcile/--supervise flag) should still run the generic pass. *)
let any_write_domain_registered () : bool =
  Hashtbl.fold (fun _ entry acc ->
    acc || (entry.Runtime.dm_diff <> None && entry.Runtime.dm_apply <> None))
    Runtime.domain_registry false
