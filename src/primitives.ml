(* pp primitives — built-in functions *)

open Types
open Backend


(* Reference to the current environment — updated by evaluator at eval entry *)
let current_env_ref : env ref = ref Types.empty_env



(* Force helpers for builtins *)
let force_val (v : value) : value = Backend.r.force v
let force_args (args : value list) : value list = List.map force_val args

(* ---- gensym (defmacro hygiene) ----

   A process-global monotonic counter, reset at the start of every fresh run
   (Evaluator.init, alongside thunk_store/handler_stack/macro table) so that
   the SAME source, run twice, expands to the byte-identical AST both times
   — gensym'd names are baked into a macro's expansion, and LAW 20 hashes
   the expanded form, so a counter that did not reset per-run would make an
   unchanged program's node keys drift from run to run.

   `~` is the marker character: reader.ml's is_symbol_char excludes it
   (alongside quote, backquote, the string-quote char, semicolon, and hash),
   and no other lexer rule claims it either (checked: token() has no case
   for `~`, so it falls to the read_symbol catch-all, which immediately
   fails with an empty-symbol lex error — `~` cannot even start a token). A
   bare `~` is therefore a genuine LEX ERROR anywhere in pp source outside a
   string literal: no user-written symbol can ever equal a gensym'd name,
   so gensym is unforgeable by construction, not merely unlikely to
   collide. *)
let gensym_counter = ref 0

(* ---- Scheduler-aware force-deep ----

   EApply forces every argument, so a compound value built by
   ordinary code forces its elements one at a time, inline — a batch of
   sibling node thunks can only exist if something built the compound value
   WITHOUT forcing its elements (the `map` primitive, below). force-deep is
   the other half: given such a batch, it is the one place that can see many
   sibling thunks before any of them are forced, so it is where the fork
   fan-out point lives.

   Two-phase protocol: (1) a non-forcing COLLECT walk over [v]'s structural
   spine gathers every reachable Unevaluated, thunk_persist thunk together
   with its LAW-20 key (tree-walker node_key_of), deduplicated by key; (2)
   those are handed to Scheduler.dispatch_batch, which forks them (up to the
   policy's concurrency) and reaps; (3) only THEN does the ordinary recursive walk
   run — every node it reaches is now a cache hit (or, for a dead worker,
   falls through to an ordinary in-process compute — worker death degrades
   to serial, never a wrong answer). Under [Serial] policy, collection is
   skipped entirely and force-deep is exactly the original one-pass walk. *)

(* Non-forcing: only pattern-matches on values already in hand, so it can
   never trigger the very one-at-a-time serialization it exists to avoid.
   [seen_pairs] is a physical-equality cycle/sharing guard (structural
   sharing from a `let`-bound sublist walked twice must not be re-collected
   or infinite-loop on a cycle); [seen_keys] is the LAW-20 dedup the
   contract requires. Stops at the boundary of a not-yet-run persistent node
   (its body is opaque until it runs) and at an ephemeral Unevaluated thunk
   (only nodes are ever batched — "What is parallelized: nodes only"). *)
let collect_unevaluated_nodes (v : value) : Scheduler.job list =
  let seen_keys : (string, unit) Hashtbl.t = Hashtbl.create 64 in
  let seen_pairs : value list ref = ref [] in
  let jobs = ref [] in
  let race_width () = match !Scheduler.policy with Scheduler.Race n -> n | _ -> 1 in
  let key_of (t : thunk) : string = Backend.r.node_key_of t
  in
  let job_run (t : thunk) (key : string) () : value =
    let run () = Backend.r.eval t.thunk_expr t.thunk_env in
    Backend.r.run_node_body ~key ~run t
  in
  let rec walk (v : value) : unit =
    match v with
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated result -> walk result
         | Evaluating -> ()
         | Unevaluated when t.thunk_persist ->
             let k = key_of t in
             if not (Hashtbl.mem seen_keys k) then begin
               Hashtbl.add seen_keys k ();
               if not (Backend.r.resolve_if_hit t k) then
                 jobs := { Scheduler.j_key = k; j_run = job_run t k;
                           j_width = race_width (); j_thunk = t }
                         :: !jobs
             end
         | Unevaluated -> () (* ephemeral: stays in-process by design *))
    | VPair (_, _) ->
        if not (List.memq v !seen_pairs) then begin
          seen_pairs := v :: !seen_pairs;
          (match v with VPair (car, cdr) -> walk car; walk cdr | _ -> ())
        end
    | VVector vs -> Array.iter walk vs
    | VMap kvs -> List.iter (fun (k, v) -> walk k; walk v) kvs
    | VSet vs -> List.iter walk vs
    | _ -> ()
  in
  walk v;
  List.rev !jobs

(* The single-pass definition — recurses into ITSELF only, never
   back into the collect/dispatch step. This is what actually walks the structure
   after (or in [Serial]'s case, instead of) a batch dispatch. Critically,
   collection must happen exactly ONCE per top-level force-deep call: were
   this walk to re-run collect_unevaluated_nodes at every level (recursing
   into [force_deep] instead of [force_deep_plain] below), each recursive
   step would re-collect the shrinking REMAINING tail — the parent's
   in-memory thunk_status stays Unevaluated until IT forces a thunk, even
   though the store already has that node's result from the first wave's
   child — and re-dispatch (and thus re-run_node_body, re-executing every
   external process) an already-computed node all over again, once per
   remaining list position (an O(n^2) blowup, not a correctness issue but a
   catastrophic performance one). *)

(* Deep force: recursively force all thunks in a data structure. Under a
   non-serial schedule policy, collects and dispatches every reachable
   unevaluated node in ONE batch BEFORE the recursive walk (see the
   two-phase protocol above), then defers entirely to the plain recursive
   walk in Force_deep — every node it reaches from here on is now a store
   hit (or, for a dead worker, an ordinary in-process compute). Under
   [Serial], collection is skipped and this is exactly the original
   single-pass definition. *)
let force_deep (v : value) : value =
  (match !Scheduler.policy with
   | Scheduler.Serial -> ()
   | Scheduler.Parallel _ | Scheduler.Race _ | Scheduler.Remote _ ->
       (match collect_unevaluated_nodes v with
        | [] -> ()
        | jobs -> Scheduler.dispatch_batch jobs));
  Force_deep.force_deep_plain v

(* ---- Probes: shared evaluate-and-pin logic ----

   One implementation, used both by the `probe` primitive (registered below)
   and by the Store-facing re-observation hook wired in main.ml
   (Runtime.probe_observer) — so a live program's `(probe name)` read and a
   later trace-verification pass compute the identical value the identical
   way and can never disagree (mirrors Runtime.proc_observer/observe_proc's
   existing shape, same reason). *)

(* Invoke a function value on already-evaluated args, without going through
   EApply: all closures go through Backend.r.apply. *)
let invoke (fn : value) (args : value list) : value =
  Backend.r.apply fn args !current_env_ref

(* Call a zero-argument function value. *)
let call_zero_arg (fn : value) : value =
  match fn with
  | VClosure c ->
      if c.params <> [] then
        failwith (Printf.sprintf
          "probe: observe-fn expects 0 arguments, got a closure of %d"
          (List.length c.params));
      invoke fn []
  | VBuiltin _ -> invoke fn []
  | _ -> failwith "probe: observe-fn is not a function"

(* Call a function value with a fixed argument list — register-domain needs
   1-arg (apply) and 2-arg (diff) calls into user-registered closures from
   OCaml orchestration (Domains.ml). *)
let call_with_args (fn : value) (args : value list) : value =
  match fn with
  | VClosure c ->
      if List.length c.params <> List.length args then
        failwith (Printf.sprintf
          "domain function expects %d argument(s), got %d"
          (List.length c.params) (List.length args));
      invoke fn args
  | VBuiltin _ -> invoke fn args
  | _ -> failwith "domain function value is not a function"

(* [Some v]: the probe's value for THIS pass — pinned in Runtime.probe_values
   after the first read, so a probe fires AT MOST ONCE per pass no matter how
   many times it is read (demand-pruned: an unread probe never fires at all,
   since this function is never called for it). [None]: no probe registered
   under [name] — the caller decides what that means (a hard error for
   `(probe name)`; an unverifiable trace cell for Store's re-observation, so
   a trace naming a probe this process never registered simply misses). *)
let probe_value_for (name : string) : value option =
  match Hashtbl.find_opt Runtime.probe_values name with
  | Some v -> Some v
  | None ->
      (match Hashtbl.find_opt Runtime.domain_registry name with
       | None -> None
       | Some entry ->
           let result =
             try call_zero_arg entry.Runtime.dm_observe
             with
             | effect (Runtime.Record_read _), k -> Effect.Deep.continue k ()
             | effect Runtime.In_node, k -> Effect.Deep.continue k false
             | effect Runtime.Get_capabilities, k -> Effect.Deep.continue k [entry.Runtime.dm_cap]
           in
           Hashtbl.replace Runtime.probe_values name result;
           Some result)

(* Store.observe_cell's "probe:" arm, via the Runtime.probe_observer hook
   (wired in main.ml). Re-observing a probe cell at hit time evaluates the
   probe (once per pass, pinned — [probe_value_for] is the SAME cache
   `(probe name)` reads below, so a node forced earlier in this pass and one
   verified later never disagree) and returns its hash for comparison
   against the recorded one. *)
let probe_observe_for_store (name : string) : string option =
  match probe_value_for name with
  | Some v -> Some (Types.hash_value v)
  | None -> None

(* Store.observe_cell's `domain:<name>:<sub>` dispatch — calls the
   registered domain's own `:observe-cell` closure (fn (sub) -> hash|nil),
   the proc_observer/probe_observer pattern generalized to third-party
   domains. Runs under the domain's own registered cap (mirrors
   probe_value_for's with_ref discipline) so a domain's O(1) targeted
   re-observation can itself read whatever it needs to answer. [None]: no
   such domain, or it declared no :observe-cell — cannot re-observe, the
   caller (Store.observe_cell) treats that as a forced miss. *)
let domain_observe_cell_for_store (name : string) (sub : string) : string option =
  match Hashtbl.find_opt Runtime.domain_registry name with
  | None -> None
  | Some { Runtime.dm_observe_cell = None; _ } -> None
  | Some { Runtime.dm_observe_cell = Some fn; dm_cap; _ } ->
      (match
         (try call_with_args fn [VString sub]
          with
          | effect (Runtime.Record_read _), k -> Effect.Deep.continue k ()
          | effect Runtime.In_node, k -> Effect.Deep.continue k false
          | effect Runtime.Get_capabilities, k -> Effect.Deep.continue k [dm_cap])
       with
       | VNil -> None
       | VString h -> Some h
       | other -> Some (Types.hash_value other))

(* A table of built-in functions: name -> value *)
let builtins : (string, value) Hashtbl.t = Hashtbl.create 64

let register (name : string) (f : value list -> value) : unit =
  Hashtbl.add builtins name (VBuiltin (name, f))

let lookup (name : string) : value option =
  Hashtbl.find_opt builtins name

(* Variadic + and *: fold from the first arg with an identity for zero args;
   int/float mixing promotes to float. A single argument is returned as-is. *)
let arith_fold (name : string) (identity : int)
    (int_op : int -> int -> int) (float_op : float -> float -> float) : unit =
  register name (fun args ->
    let args = force_args args in
    match args with
    | [] -> VInt identity
    | first :: rest ->
        List.fold_left (fun acc arg ->
          match acc, arg with
          | VInt a, VInt b -> VInt (int_op a b)
          | VInt a, VFloat b -> VFloat (float_op (float_of_int a) b)
          | VFloat a, VInt b -> VFloat (float_op a (float_of_int b))
          | VFloat a, VFloat b -> VFloat (float_op a b)
          | (VInt _ | VFloat _), v | v, _ ->
              failwith (Printf.sprintf "%s expects numbers, got %s" name (string_of_value v))
        ) first rest)

(* Variadic chained numeric comparison (< > <= >=): true iff every adjacent
   pair satisfies the operator; int/float mixing compares as float. *)
let chained_cmp (name : string)
    (int_cmp : int -> int -> bool) (float_cmp : float -> float -> bool) : unit =
  register name (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | _ ->
        let rec chained = function
          | [] | [_] -> true
          | VInt a :: VInt b :: rest -> int_cmp a b && chained (VInt b :: rest)
          | VFloat a :: VFloat b :: rest -> float_cmp a b && chained (VFloat b :: rest)
          | VInt a :: VFloat b :: rest -> float_cmp (float_of_int a) b && chained (VFloat b :: rest)
          | VFloat a :: VInt b :: rest -> float_cmp a (float_of_int b) && chained (VInt b :: rest)
          | _ -> failwith (name ^ " expects numbers")
        in
        VBool (chained args))

(* One-argument type predicate: forces the argument and tests its shape. *)
let predicate (name : string) (test : value -> bool) : unit =
  register name (fun args ->
    match args with
    | [arg] -> VBool (test (force_val arg))
    | _ -> failwith (name ^ " expects one arg"))

let initial_env () : env =
  let bindings = Hashtbl.fold (fun name v acc -> (name, v) :: acc) builtins [] in
  env_of_bindings bindings

(* ---- Register all primitives ---- *)


let register_arith () =
  (* Arithmetic — strict: force all args, variadic + and * with identity *)
  arith_fold "+" 0 ( + ) ( +. );

  register "-" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a - b)
    | [VFloat a; VFloat b] -> VFloat (a -. b)
    | _ -> failwith "- expects two numbers");

  arith_fold "*" 1 ( * ) ( *. );

  register "/" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] when b <> 0 -> VInt (a / b)
    | [VFloat a; VFloat b] when b <> 0.0 -> VFloat (a /. b)
    | _ -> failwith "/ expects two numbers (divisor not zero)");

  register "mod" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] when b <> 0 -> VInt (a mod b)
    | _ -> failwith "mod expects two integers");

  (* Comparison — strict, variadic chaining *)
  register "=" (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | a :: rest ->
        VBool (List.for_all (fun b -> try a = b with Invalid_argument _ -> a == b) rest));

  chained_cmp "<"  ( < )  ( < );
  chained_cmp ">"  ( > )  ( > );
  chained_cmp "<=" ( <= ) ( <= );
  chained_cmp ">=" ( >= ) ( >= );
  ()

let register_lists () =
  (* List operations — car/cdr force the pair, cons/list are lazy *)
  register "cons" (fun args ->
    match args with
    | [a; b] -> VPair (a, b)  (* lazy: stores thunks *)
    | _ -> failwith "cons expects two arguments");

  register "car" (fun args ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VPair (a, _) -> a  (* return car as-is, may be thunk *)
         | VNil -> VNil
         | _ -> failwith "car expects a pair")
    | _ -> failwith "car expects one argument");

  register "cdr" (fun args ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VPair (_, d) -> d  (* return cdr as-is *)
         | VNil -> VNil
         | _ -> failwith "cdr expects a pair")
    | _ -> failwith "cdr expects one argument");

  register "list" (fun args ->
    List.fold_right (fun a acc -> VPair (a, acc)) args VNil);  (* lazy *)

  (* (apply f seg1 seg2 … segN) — the reader's call-spread lowering target. Each seg is a proper
     list; apply concatenates them (in order) and calls f with the combined
     elements. The reader lowers `f(a, ...rest, b)` to
     `apply(f, list(a), rest, list(b))`, so a spread anywhere in an argument
     list becomes one apply. Only the list SPINES are forced (to splice them);
     elements pass through unforced, exactly as `cons`/`list` do, so a spread of
     unforced node thunks stays unforced — same discipline as `map`. Dispatch to
     the callee (tree-walker vs VM closure vs builtin) reuses [call_with_args],
     so both backends run it identically. *)
  register "apply" (fun args ->
    match args with
    | f :: segs ->
        let fn = force_val f in
        let rec splice l = match force_val l with
          | VNil -> []
          | VPair (a, d) -> a :: splice d
          | other -> failwith ("apply expects proper lists as its argument \
                                segments, got " ^ string_of_value other)
        in
        call_with_args fn (List.concat_map splice segs)
    | [] -> failwith "apply expects a function and at least one argument segment");

  (* (map f lst) — the missing batch fan-out point: unlike EApply, which
     forces every argument inline one at a time, `map` applies [f] to each element via the
     apply hook and conses the results WITHOUT forcing them: `(map compile
     names)` therefore yields a list of UNFORCED node thunks that
     force-deep can dispatch as one parallel batch, instead of the usual
     one-at-a-time-inline forcing every other application path gives you.
     Only the list SPINE is forced (to walk it); elements are passed through
     exactly as `cons`/`list` do.

     THE PAIRING TRAP: the mapped function's BODY must not put
     the per-element node through an argument position of its own.
     `(map (fn (n) (cons n (compile n))) names)` looks equivalent to
     pairing afterward, but it is NOT: `(compile n)` there is an argument to
     `cons`, and EApply forces every argument — strict forcing applies
     inside a closure's own body just as much as anywhere else — so each
     node is forced eagerly, one at a time,
     right there, silently serializing the whole build. Parallel fan-out
     exists exactly when the node thunk IS the mapped element: write
     `(map compile names)`, `force-deep` THAT batch, and only pair names
     with the (now-hit, already-forced) results afterward. Zero placement
     semantics of its own (LAW 34 untouched) — `map` behaves identically
     under every schedule policy, including serial. *)
  register "map" (fun args ->
    match args with
    | [f; lst] ->
        let fn = force_val f in
        (* Apply [fn] to one (possibly unforced — e.g. a node thunk) arg
           without forcing the RESULT. All closures go through
           Backend.r.apply via invoke. *)
        let apply1 (arg : value) : value =
          invoke fn [arg]
        in
        let rec go l =
          match force_val l with
          | VNil -> VNil
          | VPair (car, cdr) -> VPair (apply1 car, go cdr)
          | other -> failwith ("map expects a proper list, got " ^ string_of_value other)
        in
        go lst
    | _ -> failwith "map expects a function and a list");

  register "nil?" (fun args ->
    match args with
    | [arg] -> VBool (match force_val arg with VNil -> true | _ -> false)
    | _ -> failwith "nil? expects one argument");
  ()

let register_collections () =
  (* Vector operations — lazy *)
  register "vector" (fun args ->
    VVector (Array.of_list args));

  register "vector-get" (fun args ->
    let args = force_args args in
    match args with
    | [VVector vs; VInt i] ->
        if i >= 0 && i < Array.length vs then vs.(i)
        else failwith "vector index out of bounds"
    | _ -> failwith "vector-get expects a vector and an integer");

  (* Map operations *)
  register "hash-map" (fun args ->
    let rec make_pairs = function
      | [] -> []
      | k :: v :: rest -> (force_val k, v) :: make_pairs rest
      | _ -> failwith "hash-map expects even number of arguments"
    in
    VMap (make_pairs args));  (* keys forced, values lazy *)

  register "hash-map-get" (fun args ->
    let args = force_args args in
    match args with
    | [VMap kvs; key] ->
        (match List.find_opt (fun (k, _) -> force_val k = key) kvs with
         | Some (_, v) -> v
         | None -> VNil)
    | _ -> failwith "hash-map-get expects a map and a key");

  (* Set operations *)
  register "hash-set" (fun args ->
    VSet args);  (* lazy *)

  (* Type predicates — force to check *)
  predicate "int?"     (function VInt _ -> true | _ -> false);
  predicate "float?"   (function VFloat _ -> true | _ -> false);
  predicate "string?"  (function VString _ -> true | _ -> false);
  predicate "bool?"    (function VBool _ -> true | _ -> false);
  predicate "keyword?" (function VKeyword _ -> true | _ -> false);
  predicate "symbol?"  (function VSymbol _ -> true | _ -> false);
  predicate "pair?"    (function VPair _ | VNil -> true | _ -> false);
  predicate "vector?"  (function VVector _ -> true | _ -> false);
  predicate "map?"     (function VMap _ -> true | _ -> false);
  predicate "set?"     (function VSet _ -> true | _ -> false);
  predicate "fn?"      (function VClosure _ | VBuiltin _ -> true | _ -> false);
  register "thunk?" (fun args ->  (* unforced by design: tests thunk-ness *)
    match args with [arg] -> VBool (match arg with VThunk _ -> true | _ -> false) | _ -> failwith "thunk? expects one arg");
  ()

let register_scalars () =
  (* I/O — strict, deep-forces for display *)
  register "print" (fun args ->
    let args = List.map force_deep args in
    List.iter (fun v -> print_string (string_of_value v)) args;
    print_newline ();
    VNil);

  register "string-append" (fun args ->
    let args = force_args args in
    VString (String.concat "" (List.map (fun v ->
      match v with VString s -> s | _ -> string_of_value v
    ) args)));

  register "string-length" (fun args ->
    let args = force_args args in
    match args with
    | [VString s] -> VInt (String.length s)
    | _ -> failwith "string-length expects a string");

  register "not" (fun args ->
    match args with
    | [arg] -> VBool (match force_val arg with VBool b -> not b | VNil -> true | _ -> false)
    | _ -> failwith "not expects one argument");

  register "error" (fun args ->
    let args = force_args args in
    match args with
    | [VString msg] -> failwith msg
    | _ -> failwith "error");
  ()

let register_caps () =
  register "cap-compose" (fun args ->
    let caps = List.map (fun v -> match force_val v with VCapability c -> c | _ -> failwith "cap-compose expects capabilities") args in
    VCapability (Capability.compose caps));

  (* (current-capabilities) — reifies the ambient set AS OF THE CALL as a
     VCapability. Never a mint: it observes the ceiling the code already
     exercises on every perform (SPEC LAW 22). Callable anywhere, ambient-
     gated like every other perform path — no explicit-cap argument. *)
  register "current-capabilities" (fun args ->
    match args with
    | [] -> VCapability (Capability.compose (Effect.perform Runtime.Get_capabilities))
    | _ -> failwith "current-capabilities takes no arguments");

  register "cap-restrict" (fun args ->
    let args = force_args args in
    match args with
    | [VCapability _ as cap; VString scope] ->
        let cap = match cap with VCapability c -> c | _ -> failwith "impossible" in
        let scope = Runtime.canonical_path scope in
        VCapability (Capability.restrict cap scope)
    | [VCapability _ as cap; VString scope; VKeyword m] ->
        let cap = match cap with VCapability c -> c | _ -> failwith "impossible" in
        let mode = match m with
          | "ro" -> Capability.Read | "rw" -> Capability.ReadWrite | "wo" -> Capability.Write
          | _ -> failwith ("cap-restrict: invalid mode :" ^ m ^ " (expected :ro, :rw, or :wo)")
        in
        let scope = Runtime.canonical_path scope in
        let read_ok = Capability.check_fs_read cap scope in
        let write_ok = Capability.check_fs_write cap scope in
        let ok = match mode with
          | Capability.Read -> read_ok
          | Capability.Write -> write_ok
          | Capability.ReadWrite -> read_ok && write_ok
        in
        if not ok then
          raise (Types.Capability_error
            (Printf.sprintf
               "cap-restrict: cannot widen mode to :%s for %s (not held by the underlying capability)"
               (Capability.mode_name mode) (scope :> string)));
        VCapability (Capability.restrict ~mode cap scope)
    | _ -> failwith "cap-restrict expects a capability, a scope string, and an optional mode keyword (:ro/:rw/:wo)");

  register "cap-none" (fun args ->
    match args with [] -> VCapability Capability.none | _ -> failwith "cap-none takes no arguments");

  register "capability?" (fun args ->
    match args with [arg] -> VBool (match force_val arg with VCapability _ -> true | _ -> false) | _ -> failwith "capability? expects one arg");
  ()

let register_metaeval () =
  (* ---- eval-pp and apply-pp ---- *)

  register "eval-pp" (fun args ->
    let args = force_args args in
    match args with
    | [VString code] ->
        (* Route through the same shared expansion hook as every other
           top-level-shaped form list: eval-pp code may itself
           define or use macros, sequentially, exactly like a file's top
           level — and it must not see a stale macro table from a PRIOR
           eval-pp call, but starting a whole new one here is wrong too
           (this is emphatically not a fresh program run); simplest sound
           rule, matching the rest of this module's "macros are top-level
           file/REPL scoped" decision: eval-pp shares the CURRENT run's
           macro table, so it can use macros already defined by the calling
           program and any it defines here are visible to LATER eval-pp
           calls in the same run, but never resets between them. *)
        let exprs = Backend.r.expand_toplevel (Reader.read_string code) in
        (* Capture the calling env into a local ref — avoid clobbering
           current_env_ref during inner evaluations. *)
        let local_env = ref !current_env_ref in
        let new_defs = ref [] in
        let rec go = function
          | [] ->
              if !new_defs = [] then VNil
              else VEnvMap (List.rev !new_defs)
          | [ELocated (_, inner)] -> go [inner]
          | [EDef (name, params, body)] ->
              let closure = Types.make_closure ~name:(Some name) params body local_env in
              local_env := Types.extend_env !local_env name closure;
              new_defs := (name, closure) :: !new_defs;
              if !new_defs = [] then VNil else VEnvMap (List.rev !new_defs)
          | [EDefValue (name, rhs)] ->
              let v = Backend.r.eval rhs !local_env in
              local_env := Types.extend_env !local_env name v;
              new_defs := (name, v) :: !new_defs;
              VEnvMap (List.rev !new_defs)
          | [last] ->
              (* Pure expression: evaluate and force *)
              force_val (Backend.r.eval last !local_env)
          | (ELocated (_, inner)) :: rest -> go (inner :: rest)
          | (EDef (name, params, body)) :: rest ->
              let closure = Types.make_closure ~name:(Some name) params body local_env in
              local_env := Types.extend_env !local_env name closure;
              new_defs := (name, closure) :: !new_defs;
              go rest
          | (EDefValue (name, rhs)) :: rest ->
              let v = Backend.r.eval rhs !local_env in
              local_env := Types.extend_env !local_env name v;
              new_defs := (name, v) :: !new_defs;
              go rest
          | e :: rest ->
              ignore (force_val (Backend.r.eval e !local_env));
              go rest
        in go exprs
    | _ -> failwith "eval-pp expects a string"
  );

  register "apply-pp" (fun args ->
    let args = force_args args in
    match args with
    | [fn; args_list] ->
        let rec list_to_ocaml = function
          | VNil -> []
          | VPair (car, cdr) -> car :: list_to_ocaml cdr
          | _ -> failwith "apply-pp expects a proper list for args"
        in
        let arg_values = list_to_ocaml args_list in
        invoke fn arg_values
    | _ -> failwith "apply-pp expects fn and list of args"
  );

  (* ---- force-deep ---- *)

  register "force-deep" (fun args ->
    let args = force_args args in
    match args with
    | [v] -> force_deep v
    | _ -> failwith "force-deep expects one argument"
  );
  ()

let register_io () =
  (* ---- slurp: read file to string ---- *)

  register "slurp" (fun args ->
    let args = force_args args in
    match args with
    | [VString path] ->
        (* Node-local sandbox scratch reads are capability-free and unrecorded
           (LAW 18) — scratch is the node's working memory. Outside a
           sandbox: an fs-read grant returns plain data (CAS-ingested,
           pinned for the run), a CapSecret-only grant returns VSealed —
           bytes pinned in-memory, NEVER the CAS; see Process.read_dispatch. *)
        Process.read_dispatch ~tag:"slurp"
          ~cap_err:(fun p -> "slurp: permission denied for " ^ p) path
    | _ -> failwith "slurp expects a file path string"
  );

  (* ---- blob: ingest bytes into the CAS, return a small reference ----
     (blob S) stores S under ~/.pp/store/blobs/<sha256> and returns
     "blob:<sha256>". Desired-state maps carry these refs instead of inline
     bytes; the reconciler diffs them by hash and materializes from the
     store — which is what lets `rm -rf build/` restore with zero tool
     re-runs. *)
  register "blob" (fun args ->
    let args = force_args args in
    match args with
    | [VString s] -> VString ("blob:" ^ Store.store_blob s)
    | _ -> failwith "blob expects a string");

  (* (blob-get REF) — the inverse: "blob:<sha256>" → the stored bytes.
     Content-addressed, so no cell is recorded: the ref in a node's key or
     free vars already pins exactly these bytes. *)
  register "blob-get" (fun args ->
    let args = force_args args in
    match args with
    | [VString r] ->
        let prefix = "blob:" in
        let plen = String.length prefix in
        if String.length r > plen && String.sub r 0 plen = prefix then
          let h = String.sub r plen (String.length r - plen) in
          (match Store.load_blob h with
           | Some bytes -> VString bytes
           | None -> failwith ("blob-get: blob missing from store: " ^ h))
        else failwith ("blob-get expects a blob:<hash> reference, got " ^ r)
    | _ -> failwith "blob-get expects a blob reference string");
  ()

let register_stdlib () =
  (* ---- stdlib primitives ---- *)

  (* (hash-value V) — a canonical, structural content hash of ANY value
     (Hasher.hash_value, force-deep'd first) — order-INDEPENDENT for maps/
     sets (hash_value sorts a VMap's entries by encoded-key hash before
     hashing, exactly like Codec's on-disk canonicalization). Needed because pp's `=` on two maps is
     plain structural (assoc-list, ORDER-sensitive) list equality: a spec
     value that round-tripped through `domain-state-get/put` (Codec sorts
     VMap entries for canonical on-disk text) compares as "different" from
     the in-memory original via `=` even with identical bindings, purely
     because of key order — domain-proc.pp's diff needs a comparison that
     is not fooled by that. *)
  register "hash-value" (fun args ->
    match args with
    | [v] -> VString (Types.hash_value (force_deep (force_val v)))
    | _ -> failwith "hash-value expects one argument");

  (* (hash-string S) — SHA-256 hex digest of S's raw bytes, the SAME
     algorithm Store.hash_file_opt uses for a file's content hash (Types.
     hash_string) — needed so a domain's `diff` (domain-fs.pp) can compute a content hash from a string PURELY (no
     capability, no store I/O — unlike `blob`, this never touches
     ~/.pp/store) and compare it against what `tree-observe` observed. *)
  register "hash-string" (fun args ->
    match force_args args with
    | [VString s] -> VString (Hasher.hash_string s)
    | _ -> failwith "hash-string expects a string");

  register "number->string" (fun args ->
    match force_args args with
    | [VInt n] -> VString (string_of_int n)
    | [VFloat f] -> VString (string_of_float f)
    | _ -> failwith "number->string expects a number");

  (* (->string v) — the generic display conversion, the target of every
     f-string hole. A string renders as ITSELF (no surrounding quotes — the
     whole point of interpolation); every other value renders via
     string_of_value (numbers plain, sealed values redacted to #<sealed>, lists
     as `(a b …)`). Deep-forces so nested thunks render, like `print`. *)
  register "->string" (fun args ->
    match args with
    | [a] ->
        (match force_deep a with
         | VString s -> VString s
         | v -> VString (string_of_value v))
    | _ -> failwith "->string expects exactly one argument");

  register "string->number" (fun args ->
    match force_args args with
    | [VString s] ->
        (match int_of_string_opt s with
         | Some n -> VInt n
         | None ->
             (match float_of_string_opt s with
              | Some f -> VFloat f
              | None -> VNil))
    | _ -> failwith "string->number expects a string");

  (* (string-index S SUB) — index of the first occurrence of SUB, or nil. *)
  register "string-index" (fun args ->
    match force_args args with
    | [VString s; VString sub] ->
        let n = String.length s and m = String.length sub in
        let rec go i =
          if i + m > n then VNil
          else if String.sub s i m = sub then VInt i
          else go (i + 1)
        in go 0
    | _ -> failwith "string-index expects two strings");

  register "string-trim" (fun args ->
    match force_args args with
    | [VString s] -> VString (String.trim s)
    | _ -> failwith "string-trim expects a string");

  (* (string-sub S START LEN) *)
  register "string-sub" (fun args ->
    match force_args args with
    | [VString s; VInt start; VInt len] ->
        if start < 0 || len < 0 || start + len > String.length s then
          failwith (Printf.sprintf "string-sub: out of bounds (start %d, len %d, string length %d)"
                      start len (String.length s))
        else VString (String.sub s start len)
    | _ -> failwith "string-sub expects a string, a start index, and a length");

  (* Map utilities — keys were forced at construction; values stay lazy. *)
  register "map-keys" (fun args ->
    match force_args args with
    | [VMap kvs] -> List.fold_right (fun (k, _) acc -> VPair (k, acc)) kvs VNil
    | _ -> failwith "map-keys expects a map");

  register "map-vals" (fun args ->
    match force_args args with
    | [VMap kvs] -> List.fold_right (fun (_, v) acc -> VPair (v, acc)) kvs VNil
    | _ -> failwith "map-vals expects a map");

  register "map-remove" (fun args ->
    match args with
    | [m; k] ->
        (match force_val m with
         | VMap kvs ->
             let key = force_val k in
             VMap (List.filter (fun (k', _) -> k' <> key) kvs)
         | _ -> failwith "map-remove expects a map and a key")
    | _ -> failwith "map-remove expects a map and a key");

  (* File predicates: capability-gated observations recorded as `stat:` trace
     cells — presence/kind only, never contents, so a node that probed
     existence recomputes exactly when the path appears/disappears/changes
     kind (see Store.stat_cell_id). *)
  let stat_primitive name want_dir =
    register name (fun args ->
      match force_args args with
      | [VString path] ->
          if not (List.exists (fun cap -> Capability.check_fs_read cap (Runtime.canonical_path path))
                    (Effect.perform Runtime.Get_capabilities)) then
            raise (Types.Capability_error
                     (name ^ ": capability error: no read access for " ^ path));
          let kind = Store.stat_kind path in
          Runtime.record_read (Store.stat_cell_id path) (Store.stat_kind_hash kind);
          VBool (if want_dir then kind = "dir" else kind <> "absent")
      | _ -> failwith (name ^ " expects a path string"))
  in
  stat_primitive "file-exists?" false;
  stat_primitive "dir?" true;

  (* (argv) — program arguments after `--`, an `argv:` observation. *)
  register "argv" (fun args ->
    match args with
    | [] ->
        let av = (Runtime.invocation_get ()).program_argv in
        Runtime.record_read Store.argv_cell_id (Store.argv_observed_hash ());
        List.fold_right (fun s acc -> VPair (VString s, acc)) av VNil
    | _ -> failwith "argv takes no arguments");

  (* (env-get NAME) — environment variable or nil, an `env:` observation. *)
  register "env-get" (fun args ->
    match force_args args with
    | [VString name] ->
        let v = Sys.getenv_opt name in
        Runtime.record_read (Store.env_cell_id name) (Store.env_observed_hash v);
        (match v with Some s -> VString s | None -> VNil)
    | _ -> failwith "env-get expects a variable name string");

  (* (exit [N]) — terminate the run with status N (default 0). *)
  register "exit" (fun args ->
    match force_args args with
    | [] -> raise (Types.Pp_exit 0)
    | [VInt n] -> raise (Types.Pp_exit n)
    | _ -> failwith "exit expects an optional integer status");

  (* (string-split S SEP) — split on the single-char separator, dropping
     empty fields (manifest-file friendly: trailing newlines vanish). *)
  register "string-split" (fun args ->
    let args = force_args args in
    match args with
    | [VString s; VString sep] when String.length sep = 1 ->
        let parts = String.split_on_char sep.[0] s in
        List.fold_right (fun p acc ->
          if p = "" then acc else VPair (VString p, acc))
          parts VNil
    | _ -> failwith "string-split expects a string and a single-char separator");

  (* (map-insert M K V) — a new map with K bound to V (K forced; an existing
     binding for K is replaced). The dynamic counterpart of the {..} literal,
     for building desired-state maps by folding. *)
  register "map-insert" (fun args ->
    match args with
    | [m; k; v] ->
        (match force_val m with
         | VMap kvs ->
             let key = force_val k in
             VMap ((key, v) :: List.filter (fun (k', _) -> k' <> key) kvs)
         | _ -> failwith "map-insert expects a map, a key, and a value")
    | _ -> failwith "map-insert expects a map, a key, and a value");

  (* map-merge(a, b) — a with every binding of b inserted; b wins on collision.
     The lowering target for map spread `{ ...a, ...b }`. Keys in a VMap
     are already forced values, so structural comparison is exact. *)
  register "map-merge" (fun args ->
    match args with
    | [a; b] ->
        (match force_val a, force_val b with
         | VMap akvs, VMap bkvs ->
             let b_has k = List.exists (fun (k', _) -> k' = k) bkvs in
             VMap (bkvs @ List.filter (fun (k, _) -> not (b_has k)) akvs)
         | _ -> failwith "map-merge expects two maps")
    | _ -> failwith "map-merge expects two maps");

  (* ---- read-string: parse string to value (for pp compiler) ---- *)

  register "read-string" (fun args ->
    let args = force_args args in
    match args with
    | [VString source] ->
        let exprs = Reader.read_string source in
        (* Return as a list of quoted exprs *)
        (match exprs with
         | [e] -> Types.quote_to_value e
         | _ -> VVector (Array.of_list (List.map Types.quote_to_value exprs)))
    | _ -> failwith "read-string expects a source string"
  );
  ()

let register_domains () =
  (* ---- fenced: register a non-convergent action for reconciler sequencing
     (LAW 31).  May not appear inside a node body.  The action is not
     executed during evaluation; the active reconciler drains it after
     convergent state is applied. *)
  register "fenced" (fun args ->
    let args = force_args args in
    match args with
    | [VString kind; spec] ->
        Fenced.register kind spec;
        VNil
    | [VKeyword kind; spec] ->
        Fenced.register kind spec;
        VNil
    | _ -> failwith "fenced expects a kind string and a spec map");

  (* ---- register-domain / register-probe ----

     `(register-domain {:name :namespace :observe :diff :apply :write-cap
     [:observe-cell]})` — script-tier only (trace_stack guard, the same
     LAW-31 pattern Fenced.register uses): ordinary primitive, root/script
     scope. `:write-cap` is consumed into Runtime.domain_registry, never
     re-exposed to user code — the core-side registry IS the authority
     boundary. `:diff`/`:apply` are REQUIRED for a full domain (a domain
     with ⊥ write authority is a PROBE — register-probe below, a distinct,
     simpler entry point); `:namespace` is a list of cell-id string
     PREFIXES this domain owns (stratification, LAW 30 full form);
     `:observe-cell` is optional. Returns nil. *)
  let string_or_keyword where v =
    match string_like v with
    | Some s -> s
    | None -> failwith (where ^ ": expected a string or keyword, got "
                         ^ string_of_value v)
  in
  let find_kv = Force_deep.find_kv in
  register "register-domain" (fun args ->
    if Effect.perform Runtime.In_node then
      failwith "register-domain: may not be called inside a node body (script-tier only, like fenced)";
    let args = force_args args in
    match args with
    | [spec] ->
        let kvs = match spec with
          | VMap kvs -> kvs
          | other -> failwith ("register-domain expects a map, got " ^ string_of_value other)
        in
        let name = match find_kv kvs "name" with
          | Some v -> string_or_keyword "register-domain :name" (force_val v)
          | None -> failwith "register-domain: missing :name"
        in
        let namespace = match find_kv kvs "namespace" with
          | Some v ->
              (match force_val v with
               | VVector arr -> Array.to_list (Array.map (fun p ->
                   string_or_keyword "register-domain :namespace" (force_val p)) arr)
               | VNil -> []
               | other -> failwith ("register-domain :namespace must be a vector of strings, got "
                                    ^ string_of_value other))
          | None -> []
        in
        let observe = match find_kv kvs "observe" with
          | Some v -> force_val v
          | None -> failwith "register-domain: missing :observe"
        in
        (match observe with VClosure _ | VBuiltin _ -> ()
         | _ -> failwith "register-domain: :observe must be a function");
        let diff = Option.map force_val (find_kv kvs "diff") in
        let apply = Option.map force_val (find_kv kvs "apply") in
        let observe_cell = Option.map force_val (find_kv kvs "observe-cell") in
        let write_cap = match find_kv kvs "write-cap" with
          | Some v -> (match force_val v with
                       | VCapability c -> c
                       | other -> failwith ("register-domain :write-cap must be a capability, got "
                                            ^ string_of_value other))
          | None -> failwith "register-domain: missing :write-cap"
        in
        Hashtbl.replace Runtime.domain_registry name
          { Runtime.dm_namespace = namespace; dm_observe = observe;
            dm_diff = diff; dm_apply = apply; dm_cap = write_cap;
            dm_observe_cell = observe_cell };
        VNil
    | _ -> failwith "register-domain expects one map argument");

  (* `(register-probe name observe-fn read-cap)` — sugar over register-domain
     for the ⊥-write-authority case: dm_namespace = [] (nothing to
     stratify, core never converges it), dm_diff/dm_apply = None. Same
     surface and error text as a standalone probe registry. *)
  register "register-probe" (fun args ->
    if Effect.perform Runtime.In_node then
      failwith "register-probe: may not be called inside a node body (script-tier only, like fenced)";
    let args = force_args args in
    match args with
    | [VString name; observe_fn; VCapability read_cap]
    | [VKeyword name; observe_fn; VCapability read_cap] ->
        (match observe_fn with
         | VClosure _ | VBuiltin _ -> ()
         | _ -> failwith "register-probe: observe-fn must be a function");
        let entry = {
          Runtime.dm_namespace = [];
          dm_observe = observe_fn;
          dm_diff = None;
          dm_apply = None;
          dm_cap = read_cap;
          dm_observe_cell = None;
        } in
        Hashtbl.replace Runtime.domain_registry name entry;
        let (_ : string) = name in (* suppress unused warning *)
        VNil
    | _ -> failwith "register-probe expects a name, an observe-fn, and a read capability");
  (* ---- `probe` primitive: one-time evaluated lazy read of a registered probe ----
     a pass evaluates observe-fn (via probe_value_for, above: OUTSIDE the
     trace stack, under exactly the registered read-cap) and pins the
     result in Runtime.probe_values for the rest of the pass; every read
     (first or not) records ONLY the `probe:<name>` cell into the caller's
     trace, via the ordinary record_read every other cell-observing
     primitive uses (slurp's `file:`, env-get's `env:`, …) — capability-free
     at THIS call site, because the read-cap's authority was already spent
     evaluating the probe, not reading its pinned result. An unregistered
     name is a hard error naming it, on every read (never silently nil). *)
  register "probe" (fun args ->
    let args = force_args args in
    match args with
    | [VString name] | [VKeyword name] ->
        (match probe_value_for name with
         | None -> failwith ("probe: no such probe registered: " ^ name)
         | Some v ->
             Runtime.record_read (Cell.(to_string (Probe name))) (Types.hash_value v);
             v)
    | _ -> failwith "probe expects a probe name string");
  ()

let register_collect_and_sealed () =
  (* ---- collect: applicative/validation error-accumulation partition ---- *)

  (* `collect(items)` — partition a list of `[:ok, v]` / `[:err, e]` results.
     Returns `[:ok, values]` if all succeeded, `[:err, errors]` if any failed.
     A plain function used in pipelines (`srcs |> map(f) |> collect`); the
     validation counterpart to `try`'s short-circuit monad. Was the
     `collect-results` primitive behind the removed `collect { }` reader sugar. *)
  register "collect" (fun args ->
    let rec force_list l =
      match force_val l with
      | VNil -> []
      | VPair (h, t) -> force_val h :: force_list t
      | _ -> failwith "collect expects a list"
    in
    match args with
    | [arg] ->
        let items = force_list arg in
        let rec partition items oks errs =
          match items with
          | [] ->
              if errs = [] then
                VPair (VKeyword "ok",
                  VPair (List.fold_right (fun a acc -> VPair (a, acc)) (List.rev oks) VNil, VNil))
              else
                VPair (VKeyword "err",
                  VPair (List.fold_right (fun a acc -> VPair (a, acc)) (List.rev errs) VNil, VNil))
          | VPair (VKeyword "ok", VPair (v, VNil)) :: rest ->
              partition rest (v :: oks) errs
          | VPair (VKeyword "err", VPair (e, VNil)) :: rest ->
              partition rest oks (e :: errs)
          | other :: _ ->
              failwith ("collect: each item must be [:ok, v] or [:err, e], got "
                        ^ string_of_value other)
        in
        partition items [] []
    | _ -> failwith "collect expects one argument");
  (* ---- Sealed cells ---- *)

  (* `(unseal v)` — the one sanctioned way out of VSealed to VString (the
     explicit, greppable Vault/SOPS-style boundary; derived data is ordinary
     data afterward — no dataflow tainting, by design). Anything else is a
     hard error naming the mistake. *)
  register "unseal" (fun args ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VSealed bytes -> VString bytes
         | other -> failwith ("unseal expects a sealed value, got " ^ string_of_value other))
    | _ -> failwith "unseal expects one argument");
  ()

let register_ppc () =
  register "ppc-emit-opcode" (fun _args ->
    failwith "ppc-emit-opcode: not yet implemented for self-hosting"
  );

  register "ppc-emit-constant" (fun _args ->
    failwith "ppc-emit-constant: not yet implemented for self-hosting"
  );

  register "ppc-resolve-local" (fun args ->
    failwith "ppc-resolve-local: not yet implemented for self-hosting"
  );

  register "ppc-push-cenv-frame" (fun args ->
    failwith "ppc-push-cenv-frame: not yet implemented for self-hosting"
  );

  register "ppc-pop-cenv-frame" (fun args ->
    failwith "ppc-pop-cenv-frame: not yet implemented for self-hosting"
  );
  ()

let register_macros () =
  let rec quasiquote_walk v =
    match v with
    | VPair (VSymbol "unquote", VPair (arg, VNil)) -> arg
    | VPair (VPair (VSymbol "unquote-splicing", VPair (spliced, VNil)), cdr) ->
        (* Splice: append the walked cdr to the spliced list *)
        qq_append spliced (quasiquote_walk cdr)
    | VPair (car, cdr) ->
        VPair (quasiquote_walk car, quasiquote_walk cdr)
    | VVector arr ->
        VVector (Array.map quasiquote_walk arr)
    | other -> other

  and qq_append a b =
    match a with
    | VNil -> b
    | VPair (x, xs) -> VPair (x, qq_append xs b)
    | _ -> failwith "unquote-splicing expects a list"
  in

  register "quasiquote" (fun args ->
    let args = force_args args in
    match args with
    | [v] -> quasiquote_walk v
    | _ -> failwith "quasiquote expects one argument"
  );

  register "unquote" (fun _ ->
    failwith "unquote not allowed outside quasiquote"
  );

  register "unquote-splicing" (fun _ ->
    failwith "unquote-splicing not allowed outside quasiquote"
  );

  (* (gensym) / (gensym "prefix") — a fresh, genuinely-unwritable symbol
     (see gensym_counter's comment above). The macro-authoring discipline
     (documented, not enforced): use gensym for every binding a macro
     INTRODUCES; splice caller-supplied forms in via quasiquote/unquote
     verbatim, never renamed. Without it, a macro's own temporary bindings
     can capture (or be captured by) the call site's bindings — pp macros
     are deliberately unhygienic: full hygiene is not
     required for a Lisp-1 with explicit quasiquote. *)
  register "gensym" (fun args ->
    let prefix = match force_args args with
      | [] -> "g"
      | [VString p] -> p
      | [VSymbol p] -> p
      | _ -> failwith "gensym expects an optional string/symbol prefix"
    in
    incr gensym_counter;
    VSymbol (Printf.sprintf "%s~%d" prefix !gensym_counter));
  ()

let register_match_aliases () =
  (* Unshadowable aliases for the primitives the `match` lowering
     compiles its structural condition/binding code
     down to. Register each of
     these under a NUL-prefixed name — no pp source can contain a NUL,
     so no `def`/`let` can ever rebind it — pointing at the SAME builtin
     value already registered under the plain name. The lowering
     references the "\000"-prefixed name instead of the plain
     one, so it always reaches the true primitive regardless of
     shadowing. *)
  List.iter (fun n ->
    match lookup n with
    | Some v -> Hashtbl.replace builtins ("\000" ^ n) v
    | None -> failwith ("A5: expected primitive " ^ n ^ " to already be registered")
  ) ["car"; "cdr"; "="; "nil?"; "not"; "error"; "pair?"]

  ;
  ()

(* Every primitive registered at module load, grouped by family. The
   match-alias step must run last: it aliases already-registered names
   (car/cdr/=/nil?/not/error/pair?) under NUL-prefixed, unshadowable keys. *)
let () =
  register_arith ();
  register_lists ();
  register_collections ();
  register_scalars ();
  register_caps ();
  register_metaeval ();
  register_io ();
  register_stdlib ();
  register_domains ();
  register_collect_and_sealed ();
  register_ppc ();
  register_macros ();
  register_match_aliases ()
