open Pp_frontend
open Pp_kernel
(* pp primitives — built-in functions *)

open Core_model
open Source_error
open Primitive_catalog

let session () = Effect.perform Dynamic_scope.Get_session
let core_operations () = Session.core_operations (session ())

(* Force helpers for builtins *)
let force_val (v : value) : value = (core_operations ()).force v
let force_args (args : value list) : value list = List.map force_val args

let map_fields value =
  match force_val value with
  | VMap fields -> fields
  | other -> failwith ("runtime manifest expects a map, got " ^
      Presentation.string_of_value other)

let field fields name =
  match Force_deep.find_kv ~force:force_val fields name with
  | Some value -> Some (force_val value)
  | None -> None

let string_field fields name =
  match field fields name with
  | Some (VString value) | Some (VKeyword value) -> value
  | Some value -> failwith (Printf.sprintf "runtime manifest :%s expects a string or keyword, got %s"
      name (Presentation.string_of_value value))
  | None -> failwith ("runtime manifest: missing :" ^ name)

let int_field fields name =
  match field fields name with
  | Some (VInt value) when value > 0 -> value
  | Some value -> failwith (Printf.sprintf "runtime manifest :%s expects a positive integer, got %s"
      name (Presentation.string_of_value value))
  | None -> failwith ("runtime manifest: missing :" ^ name)

let runtime_schedule spec =
  let fields = map_fields spec in
  match string_field fields "kind" with
  | "serial" -> Scheduler.Serial
  | "parallel" -> Scheduler.Parallel (int_field fields "width")
  | "race" -> Scheduler.Race (int_field fields "width")
  | kind -> failwith ("runtime manifest: unknown schedule kind " ^ kind)

let custom_plan_value jobs policy =
  let descriptors = VVector (Array.of_list (List.mapi (fun index job ->
    VMap [
      VKeyword "index", VInt index;
      VKeyword "key", VString (Identity_types.Node_key.to_string job.Scheduler.j_key);
      VKeyword "width", VInt job.Scheduler.j_width
    ]) jobs)) in
  let result = Dynamic_scope.with_capabilities [] (fun () ->
    Session.call (session ()) ~env:Environment.empty policy [descriptors]) in
  let fields = map_fields result in
  let mode = string_field fields "mode" in
  let mode = match mode with
    | "serial" -> Scheduler.Serial_batch
    | "parallel" -> Scheduler.Parallel_batch (int_field fields "width")
    | "race" -> Scheduler.Race_batch (int_field fields "width")
    | "remote" -> Scheduler.Remote_batch (string_field fields "member")
    | other -> failwith ("scheduler policy returned unknown mode " ^ other)
  in
  let batches = match field fields "batches" with
    | Some (VVector batches) -> Array.to_list (Array.map (fun batch ->
        match force_val batch with
        | VVector indexes -> Array.to_list (Array.map (fun index ->
            match force_val index with
            | VInt index -> index
            | other -> failwith ("scheduler policy batch index must be an integer, got " ^
                Presentation.string_of_value other)) indexes)
        | other -> failwith ("scheduler policy batch must be a vector, got " ^
            Presentation.string_of_value other)) batches)
    | Some other -> failwith ("scheduler policy :batches must be a vector, got " ^
        Presentation.string_of_value other)
    | None -> failwith "scheduler policy: missing :batches"
  in
  { Scheduler.mode; batches }

let custom_scheduler spec =
  let fields = map_fields spec in
  let policy = match field fields "policy" with
    | Some (VClosure _ | VBuiltin _) as value -> Option.get value
    | Some value -> failwith ("custom schedule :policy expects a function, got " ^
        Presentation.string_of_value value)
    | None -> failwith "custom schedule: missing :policy"
  in
  let redundancy = match field fields "redundancy" with
    | None -> 1
    | Some (VInt value) when value > 0 -> value
    | Some value -> failwith ("custom schedule :redundancy expects a positive integer, got " ^
        Presentation.string_of_value value)
  in
  Scheduler.custom ~name:"custom" ~redundancy
    ~remote_dispatch:(match Session.remote_dispatch (session ()) with
      | Some dispatch -> dispatch
      | None -> (fun ~member:_ _ ->
          failwith "custom schedule: remote execution requires host configuration"))
    ~plan:(fun jobs -> custom_plan_value jobs policy)

let validate_manifest fields =
  List.iter (fun (key, value) ->
    let name = match key with
      | VKeyword name | VString name -> name
      | other -> failwith ("runtime manifest keys must be keywords or strings, got " ^
          Presentation.string_of_value other)
    in
    if not (List.mem name ["schedule"; "reporter"; "build-policy";
                           "execution-policy"]) then
      failwith ("runtime manifest has unknown field :" ^ name);
    if name = "build-policy" || name = "execution-policy" then
      if Codec.encode_value (Force_deep.force_deep value) = None then
        failwith ("runtime manifest :" ^ name ^ " must be canonical data");
    if name = "schedule" then ignore (map_fields value)) fields;
  fields

(* ---- gensym (defmacro hygiene) ----

   A process-global monotonic counter, reset at the start of every fresh run
   (Evaluator.init, alongside thunk_store/handler_stack/macro table) so that
   the SAME source, run twice, expands to the byte-identical AST both times
   — gensym'd names are baked into a macro's expansion, and identity hashes
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

let catalog = Primitive_catalog.create ()
let register = Primitive_catalog.register catalog

let lookup (name : string) : value option =
  Primitive_catalog.lookup catalog name

(* Variadic + and *: fold from the first arg with an identity for zero args;
   int/float mixing promotes to float. A single argument is returned as-is. *)
let arith_fold ~declare (name : string) (identity : int)
    (int_op : int -> int -> int) (float_op : float -> float -> float) : unit =
  declare ~shape:(Range (0, None)) name (fun args _env ->
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
              failwith (Printf.sprintf "%s expects numbers, got %s" name (Presentation.string_of_value v))
        ) first rest)

(* Variadic chained numeric comparison (< > <= >=): true iff every adjacent
   pair satisfies the operator; int/float mixing compares as float. *)
let chained_cmp ~declare (name : string)
    (int_cmp : int -> int -> bool) (float_cmp : float -> float -> bool) : unit =
  declare ~shape:(Range (0, None)) name (fun args _env ->
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
let predicate ~declare (name : string) (test : value -> bool) : unit =
  declare ~shape:(Exact 1) name (fun args _env ->
    match args with
    | [arg] -> VBool (test (force_val arg))
    | _ -> failwith (name ^ " expects one arg"))

let initial_env () : env =
  Primitive_catalog.initial_env catalog

(* ---- Register all primitives ---- *)


let register_arith () =
  let register = register ~category:Arithmetic in
  let declare ~shape name implementation = register ~shape name implementation in
  (* Arithmetic — strict: force all args, variadic + and * with identity *)
  arith_fold ~declare "+" 0 ( + ) ( +. );

  register "-" (fun args _env ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a - b)
    | [VFloat a; VFloat b] -> VFloat (a -. b)
    | _ -> failwith "- expects two numbers");

  arith_fold ~declare "*" 1 ( * ) ( *. );

  register "/" (fun args _env ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] when b <> 0 -> VInt (a / b)
    | [VFloat a; VFloat b] when b <> 0.0 -> VFloat (a /. b)
    | _ -> failwith "/ expects two numbers (divisor not zero)");

  register "mod" (fun args _env ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] when b <> 0 -> VInt (a mod b)
    | _ -> failwith "mod expects two integers");

  (* Comparison — strict, variadic chaining *)
  register "=" (fun args _env ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | a :: rest ->
        VBool (List.for_all (fun b -> try a = b with Invalid_argument _ -> a == b) rest));

  chained_cmp ~declare "<"  ( < )  ( < );
  chained_cmp ~declare ">"  ( > )  ( > );
  chained_cmp ~declare "<=" ( <= ) ( <= );
  chained_cmp ~declare ">=" ( >= ) ( >= );
  ()

let register_lists () =
  let register = register ~category:Collections in
  (* List operations — car/cdr force the pair, cons/list are lazy *)
  register "cons" (fun args _env ->
    match args with
    | [a; b] -> VPair (a, b)  (* lazy: stores thunks *)
    | _ -> failwith "cons expects two arguments");

  register "car" (fun args _env ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VPair (a, _) -> a  (* return car as-is, may be thunk *)
         | VNil -> VNil
         | _ -> failwith "car expects a pair")
    | _ -> failwith "car expects one argument");

  register "cdr" (fun args _env ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VPair (_, d) -> d  (* return cdr as-is *)
         | VNil -> VNil
         | _ -> failwith "cdr expects a pair")
    | _ -> failwith "cdr expects one argument");

  register "list" (fun args _env ->
    List.fold_right (fun a acc -> VPair (a, acc)) args VNil);  (* lazy *)

  (* (apply f seg1 seg2 … segN) — the reader's call-spread lowering target. Each seg is a proper
     list; apply concatenates them (in order) and calls f with the combined
     elements. The reader lowers `f(a, ...rest, b)` to
     `apply(f, list(a), rest, list(b))`, so a spread anywhere in an argument
     list becomes one apply. Only the list SPINES are forced (to splice them);
     elements pass through unforced, exactly as `cons`/`list` do, so a spread of
     unforced node thunks stays unforced — same discipline as `map`. Dispatch to
     the callee (closure or builtin) reuses the session's explicit call
     operation. *)
  register ~shape:(Range (2, None)) "apply" (fun args env ->
    match args with
    | f :: segs ->
        let fn = force_val f in
        let rec splice l = match force_val l with
          | VNil -> []
          | VPair (a, d) -> a :: splice d
          | other -> failwith ("apply expects proper lists as its argument \
                                segments, got " ^ Presentation.string_of_value other)
        in
        Session.call (session ()) ~env fn (List.concat_map splice segs)
    | [] -> failwith "apply expects a function and at least one argument segment");

  (* (map f lst) — the missing batch fan-out point: unlike EApply, which
     forces every argument inline one at a time, `map` applies [f] to each element via the
     evaluator apply operation and conses the results WITHOUT forcing them: `(map compile
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
     semantics of its own — `map` behaves identically
     under every schedule policy, including serial. *)
  register ~shape:(Exact 2) "map" (fun args env ->
    match args with
    | [f; lst] ->
        let fn = force_val f in
        (* Apply [fn] to one (possibly unforced — e.g. a node thunk) arg
           without forcing the RESULT. All closures go through
           the evaluator apply operation via the session's explicit call
           operation. *)
        let apply1 (arg : value) : value =
          Session.call (session ()) ~env fn [arg]
        in
        let rec collect reversed l =
          match force_val l with
          | VNil -> reversed
          | VPair (car, cdr) -> collect (car :: reversed) cdr
          | other -> failwith ("map expects a proper list, got " ^ Presentation.string_of_value other)
        in
        List.fold_left (fun tail value -> VPair (apply1 value, tail)) VNil
          (collect [] lst)
    | _ -> failwith "map expects a function and a list");

  register "nil?" (fun args _env ->
    match args with
    | [arg] -> VBool (match force_val arg with VNil -> true | _ -> false)
    | _ -> failwith "nil? expects one argument");
  ()

let register_collections () =
  let register = register ~category:Collections in
  let declare ~shape name implementation = register ~shape name implementation in
  (* Vector operations — lazy *)
  register "vector" (fun args _env ->
    VVector (Array.of_list args));

  register "vector-get" (fun args _env ->
    let args = force_args args in
    match args with
    | [VVector vs; VInt i] ->
        if i >= 0 && i < Array.length vs then vs.(i)
        else failwith "vector index out of bounds"
    | _ -> failwith "vector-get expects a vector and an integer");

  register "vector-length" (fun args _env ->
    match force_args args with
    | [VVector vs] -> VInt (Array.length vs)
    | _ -> failwith "vector-length expects a vector");

  (* Map operations *)
  register "hash-map" (fun args _env ->
    let rec make_pairs = function
      | [] -> []
      | k :: v :: rest -> (force_val k, v) :: make_pairs rest
      | _ -> failwith "hash-map expects even number of arguments"
    in
    VMap (make_pairs args));  (* keys forced, values lazy *)

  register "hash-map-get" (fun args _env ->
    let args = force_args args in
    match args with
    | [VMap kvs; key] ->
        (match List.find_opt (fun (k, _) -> force_val k = key) kvs with
         | Some (_, v) -> v
         | None -> VNil)
    | _ -> failwith "hash-map-get expects a map and a key");

  (* Set operations *)
  register "hash-set" (fun args _env ->
    VSet args);  (* lazy *)

  register "set->list" (fun args _env ->
    match force_args args with
    | [VSet values] ->
        List.fold_right (fun value acc -> VPair (value, acc)) values VNil
    | _ -> failwith "set->list expects a set");

  (* Type predicates — force to check *)
  predicate ~declare "int?"     (function VInt _ -> true | _ -> false);
  predicate ~declare "float?"   (function VFloat _ -> true | _ -> false);
  predicate ~declare "string?"  (function VString _ -> true | _ -> false);
  predicate ~declare "bool?"    (function VBool _ -> true | _ -> false);
  predicate ~declare "keyword?" (function VKeyword _ -> true | _ -> false);
  predicate ~declare "symbol?"  (function VSymbol _ -> true | _ -> false);
  predicate ~declare "pair?"    (function VPair _ | VNil -> true | _ -> false);
  predicate ~declare "vector?"  (function VVector _ -> true | _ -> false);
  predicate ~declare "map?"     (function VMap _ -> true | _ -> false);
  predicate ~declare "set?"     (function VSet _ -> true | _ -> false);
  predicate ~declare "fn?"      (function VClosure _ | VBuiltin _ -> true | _ -> false);
  register "thunk?" (fun args _env ->  (* unforced by design: tests thunk-ness *)
    match args with [arg] -> VBool (match arg with VThunk _ -> true | _ -> false) | _ -> failwith "thunk? expects one arg");
  ()

let register_scalars () =
  let register = register ~category:Strings in
  (* I/O — strict, deep-forces for display *)
  register "print" (fun args _env ->
    let args = List.map Force_deep.force_deep args in
    List.iter (fun v -> print_string (Presentation.string_of_value v)) args;
    print_newline ();
    VNil);

  register "string-append" (fun args _env ->
    let args = force_args args in
    VString (String.concat "" (List.map (fun v ->
      match v with VString s -> s | _ -> Presentation.string_of_value v
    ) args)));

  register "string-length" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString s] -> VInt (String.length s)
    | _ -> failwith "string-length expects a string");

  register "not" (fun args _env ->
    match args with
    | [arg] -> VBool (match force_val arg with VBool b -> not b | VNil -> true | _ -> false)
    | _ -> failwith "not expects one argument");

  register "error" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString msg] -> failwith msg
    | _ -> failwith "error");
  ()

let register_caps () =
  let register = register ~category:Capabilities in
  let current_capabilities () =
    VCapability (Capability.compose (Effect.perform Dynamic_scope.Get_capabilities))
  in
  register "cap-compose" (fun args _env ->
    let caps = List.map (fun v -> match force_val v with VCapability c -> c | _ -> failwith "cap-compose expects capabilities") args in
    VCapability (Capability.compose caps));

  (* (current-capabilities) — reifies the ambient set AS OF THE CALL as a
     VCapability. Never a mint: it observes the ceiling the code already
     exercises on every perform. Callable anywhere, ambient-
     gated like every other perform path — no explicit-cap argument. *)
  register "current-capabilities" (fun args _env ->
    Dynamic_scope.require_script_tier
      "current-capabilities: may not be called inside a node body (scripting-tier only)";
    match args with
    | [] -> current_capabilities ()
    | _ -> failwith "current-capabilities takes no arguments");

  register "\000needs-current-capabilities" (fun args _env ->
    match args with
    | [] ->
        VCapability
          (Capability.compose (Effect.perform Dynamic_scope.Get_capabilities))
    | _ -> failwith "needs capability projection takes no arguments");

  register "cap-restrict" (fun args _env ->
    let args = force_args args in
    match args with
    | [VCapability _ as cap; VString scope] ->
        let cap = match cap with VCapability c -> c | _ -> failwith "impossible" in
        let scope = World_path.canonical scope in
        VCapability (Capability.restrict cap scope)
    | [VCapability _ as cap; VString scope; VKeyword m] ->
        let cap = match cap with VCapability c -> c | _ -> failwith "impossible" in
        let mode = match m with
          | "ro" -> Capability.Read | "rw" -> Capability.ReadWrite | "wo" -> Capability.Write
          | _ -> failwith ("cap-restrict: invalid mode :" ^ m ^ " (expected :ro, :rw, or :wo)")
        in
        let scope = World_path.canonical scope in
        let read_ok = Capability.check_fs_read cap scope in
        let write_ok = Capability.check_fs_write cap scope in
        let ok = match mode with
          | Capability.Read -> read_ok
          | Capability.Write -> write_ok
          | Capability.ReadWrite -> read_ok && write_ok
        in
        if not ok then
          capability
            (Printf.sprintf
               "cap-restrict: cannot widen mode to :%s for %s (not held by the underlying capability)"
               (Capability.mode_name mode) (scope :> string));
        VCapability (Capability.restrict ~mode cap scope)
    | _ -> failwith "cap-restrict expects a capability, a scope string, and an optional mode keyword (:ro/:rw/:wo)");

  register "cap-none" (fun args _env ->
    match args with [] -> VCapability Capability.none | _ -> failwith "cap-none takes no arguments");

  register "capability?" (fun args _env ->
    match args with [arg] -> VBool (match force_val arg with VCapability _ -> true | _ -> false) | _ -> failwith "capability? expects one arg");
  ()

let register_metaeval () =
  let register = register ~category:Metaprogramming in
  (* ---- eval-pp and apply-pp ---- *)

  register ~shape:(Exact 1) "eval-pp" (fun args env ->
    let args = force_args args in
    match args with
    | [VString code] ->
        (* Route through the same shared expansion boundary as every other
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
        let core = core_operations () in
        let macro_services = {
          Macro.eval = core.eval;
          force_deep = Force_deep.force_deep;
          initial_env;
        } in
        let exprs = Macro.expand_toplevel_list macro_services (Reader.read_string code) in
        let local_env = ref env in
        let new_defs = ref [] in
        let rec go = function
          | [] ->
              if !new_defs = [] then VNil
              else VEnvMap (List.rev !new_defs)
          | [ELocated (_, inner)] -> go [inner]
          | [EDef (name, params, body)] ->
              let closure = Environment.make_definition ~name ~kind:Function params body local_env in
              local_env := Environment.extend !local_env name closure;
              new_defs := (name, closure) :: !new_defs;
              if !new_defs = [] then VNil else VEnvMap (List.rev !new_defs)
          | [EDefValue (name, rhs)] ->
              let v = core.eval rhs !local_env in
              local_env := Environment.extend !local_env name v;
              new_defs := (name, v) :: !new_defs;
              VEnvMap (List.rev !new_defs)
          | [last] ->
              (* Pure expression: evaluate and force *)
              force_val (core.eval last !local_env)
          | (ELocated (_, inner)) :: rest -> go (inner :: rest)
          | (EDef (name, params, body)) :: rest ->
              let closure = Environment.make_definition ~name ~kind:Function params body local_env in
              local_env := Environment.extend !local_env name closure;
              new_defs := (name, closure) :: !new_defs;
              go rest
          | (EDefValue (name, rhs)) :: rest ->
              let v = core.eval rhs !local_env in
              local_env := Environment.extend !local_env name v;
              new_defs := (name, v) :: !new_defs;
              go rest
          | e :: rest ->
              ignore (force_val (core.eval e !local_env));
              go rest
        in go exprs
    | _ -> failwith "eval-pp expects a string"
  );

  register ~shape:(Exact 2) "apply-pp" (fun args env ->
    let args = force_args args in
    match args with
    | [fn; args_list] ->
        let rec list_to_ocaml = function
          | VNil -> []
          | VPair (car, cdr) -> car :: list_to_ocaml cdr
          | _ -> failwith "apply-pp expects a proper list for args"
        in
        let arg_values = list_to_ocaml args_list in
        Session.call (session ()) ~env fn arg_values
    | _ -> failwith "apply-pp expects fn and list of args"
  );

  (* ---- force-deep ---- *)

  register ~shape:(Exact 1) "force-deep" (fun args _env ->
    let args = force_args args in
    match args with
    | [v] -> Force_deep.force_deep v
    | _ -> failwith "force-deep expects one argument"
  );
  ()

let register_io () =
  let register = register ~category:Observations in
  (* ---- slurp: read file to string ---- *)

  register "slurp" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString path] ->
        (* Node-local sandbox scratch reads are capability-free and unrecorded.
           Scratch is the node's working memory. Outside a
           sandbox: an fs-read grant returns plain data (CAS-ingested,
           pinned for the run), a CapSecret-only grant returns VSealed —
           bytes pinned in-memory, NEVER the CAS; see Process.read_dispatch. *)
        Process.read_dispatch ~tag:"slurp"
          ~cap_err:(fun p -> "slurp: permission denied for " ^ p) path
    | _ -> failwith "slurp expects a file path string"
  );

  register "blob" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString s] -> VString (Blob_repository.put Blob_repository.default s)
    | _ -> failwith "blob expects a string");

  register "blob-get" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString hash] ->
        (match Blob_repository.get Blob_repository.default hash with
         | Some bytes when Hasher.hash_string bytes = hash -> VString bytes
         | Some _ -> failwith ("blob-get: blob hash mismatch: " ^ hash)
         | None -> failwith ("blob-get: blob missing from store: " ^ hash))
    | _ -> failwith "blob-get expects a blob identity string");
  ()

let register_stdlib () =
  let register = register ~category:Other in
  (* ---- stdlib primitives ---- *)

  (* (hash-value V) — a canonical, structural content hash of ANY value
     (Identity.hash_value, force-deep'd first) — order-INDEPENDENT for maps/
     sets (Identity.hash_value sorts a VMap's entries by encoded-key hash before
     hashing, exactly like Codec's on-disk canonicalization). Needed because pp's `=` on two maps is
     plain structural (assoc-list, ORDER-sensitive) list equality: a spec
     value that round-tripped through `domain-state-get/put` (Codec sorts
     VMap entries for canonical on-disk text) compares as "different" from
     the in-memory original via `=` even with identical bindings, purely
     because of key order — domain-proc.pp's diff needs a comparison that
     is not fooled by that. *)
  register "hash-value" (fun args _env ->
    match args with
    | [v] -> VString (Identity.hash_value (Force_deep.force_deep (force_val v)))
    | _ -> failwith "hash-value expects one argument");

  (* (hash-string S) — SHA-256 hex digest of S's raw bytes, the SAME
     algorithm Observation.hash_file uses for a file's content hash (Core_model.
     Hasher.hash_string) — needed so a domain's `diff` (domain-fs.pp) can compute a content hash from a string PURELY (no
     capability, no store I/O — unlike `blob`, this never touches
     ~/.pp/store) and compare it against what `tree-observe` observed. *)
  register "hash-string" (fun args _env ->
    match force_args args with
    | [VString s] -> VString (Hasher.hash_string s)
    | _ -> failwith "hash-string expects a string");

  register "number->string" (fun args _env ->
    match force_args args with
    | [VInt n] -> VString (string_of_int n)
    | [VFloat f] -> VString (string_of_float f)
    | _ -> failwith "number->string expects a number");

  (* (->string v) — the generic display conversion, the target of every
     f-string hole. A string renders as ITSELF (no surrounding quotes — the
     whole point of interpolation); every other value renders via
     Presentation.string_of_value (numbers plain, sealed values redacted to #<sealed>, lists
     as `(a b …)`). Deep-forces so nested thunks render, like `print`. *)
  register "->string" (fun args _env ->
    match args with
    | [a] ->
        (match Force_deep.force_deep a with
         | VString s -> VString s
         | v -> VString (Presentation.string_of_value v))
    | _ -> failwith "->string expects exactly one argument");

  register "string->number" (fun args _env ->
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
  register "string-index" (fun args _env ->
    match force_args args with
    | [VString s; VString sub] ->
        let n = String.length s and m = String.length sub in
        let rec go i =
          if i + m > n then VNil
          else if String.sub s i m = sub then VInt i
          else go (i + 1)
        in go 0
    | _ -> failwith "string-index expects two strings");

  register "string-trim" (fun args _env ->
    match force_args args with
    | [VString s] -> VString (String.trim s)
    | _ -> failwith "string-trim expects a string");

  (* (string-sub S START LEN) *)
  register "string-sub" (fun args _env ->
    match force_args args with
    | [VString s; VInt start; VInt len] ->
        if start < 0 || len < 0 || start + len > String.length s then
          failwith (Printf.sprintf "string-sub: out of bounds (start %d, len %d, string length %d)"
                      start len (String.length s))
        else VString (String.sub s start len)
    | _ -> failwith "string-sub expects a string, a start index, and a length");

  (* Map utilities — keys were forced at construction; values stay lazy. *)
  register "map-keys" (fun args _env ->
    match force_args args with
    | [VMap kvs] -> List.fold_right (fun (k, _) acc -> VPair (k, acc)) kvs VNil
    | _ -> failwith "map-keys expects a map");

  register "map-vals" (fun args _env ->
    match force_args args with
    | [VMap kvs] -> List.fold_right (fun (_, v) acc -> VPair (v, acc)) kvs VNil
    | _ -> failwith "map-vals expects a map");

  register "map-remove" (fun args _env ->
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
     kind. *)
  let stat_primitive name want_dir =
    register name (fun args _env ->
      match force_args args with
      | [VString path] ->
          if not (List.exists (fun cap -> Capability.check_fs_read cap (World_path.canonical path))
                    (Effect.perform Dynamic_scope.Get_capabilities)) then
            capability (name ^ ": capability error: no read access for " ^ path);
          let kind = Observation.stat_kind path in
          Observation.record (Observation.stat path) (Observation.stat_hash kind);
          VBool (if want_dir then kind = "dir" else kind <> "absent")
      | _ -> failwith (name ^ " expects a path string"))
  in
  stat_primitive "file-exists?" false;
  stat_primitive "dir?" true;

  (* (argv) — program arguments after `--`, an `argv:` observation. *)
  register "argv" (fun args _env ->
    match args with
    | [] ->
        let av = Invocation.program_argv (Effect.perform Dynamic_scope.Get_invocation) in
        Observation.record Cell.Argv (Observation.argv_hash av);
        List.fold_right (fun s acc -> VPair (VString s, acc)) av VNil
    | _ -> failwith "argv takes no arguments");

  (* (env-get NAME) — environment variable or nil, an `env:` observation. *)
  register "env-get" (fun args _env ->
    match force_args args with
    | [VString name] ->
        let v = Sys.getenv_opt name in
        Observation.record (Cell.Env name) (Observation.env_hash v);
        (match v with Some s -> VString s | None -> VNil)
    | _ -> failwith "env-get expects a variable name string");

  (* (exit [N]) — terminate the run with status N (default 0). *)
  register "exit" (fun args _env ->
    match force_args args with
    | [] -> raise (Source_error.Pp_exit 0)
    | [VInt n] -> raise (Source_error.Pp_exit n)
    | _ -> failwith "exit expects an optional integer status");

  (* (string-split S SEP) — split on any non-empty separator and preserve
     empty fields. *)
  register "string-split" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString s; VString sep] when String.length sep > 0 ->
        let n = String.length s and m = String.length sep in
        let rec collect start acc =
          if start > n then List.rev acc
          else
            let rec find i =
              if i + m > n then None
              else if String.sub s i m = sep then Some i
              else find (i + 1)
            in
            match find start with
            | None -> List.rev (String.sub s start (n - start) :: acc)
            | Some i -> collect (i + m) (String.sub s start (i - start) :: acc)
        in
        List.fold_right (fun p acc -> VPair (VString p, acc))
          (collect 0 []) VNil
    | _ -> failwith "string-split expects a string and a non-empty separator");

  (* (map-insert M K V) — a new map with K bound to V (K forced; an existing
     binding for K is replaced). The dynamic counterpart of the {..} literal,
     for building desired-state maps by folding. *)
  register "map-insert" (fun args _env ->
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
  register "map-merge" (fun args _env ->
    match args with
    | [a; b] ->
        (match force_val a, force_val b with
         | VMap akvs, VMap bkvs ->
             let b_has k = List.exists (fun (k', _) -> k' = k) bkvs in
             VMap (bkvs @ List.filter (fun (k, _) -> not (b_has k)) akvs)
         | _ -> failwith "map-merge expects two maps")
    | _ -> failwith "map-merge expects two maps");

  (* ---- read-string: parse string to value (for pp compiler) ---- *)

  register "read-string" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString source] ->
        let exprs = Reader.read_string source in
        (* Return as a list of quoted exprs *)
        (match exprs with
         | [e] -> Quotation.quote_to_value e
         | _ -> VVector (Array.of_list (List.map Quotation.quote_to_value exprs)))
    | _ -> failwith "read-string expects a source string"
  );
  ()

let register_domains () =
  let register = register ~category:Domains in
  register "configure-runtime" (fun args _env ->
    if Effect.perform Dynamic_scope.In_node then
      failwith "configure-runtime: may not be called inside a node body";
    match args with
    | [spec] ->
        let fields = map_fields spec in
        let fields = validate_manifest fields in
        Session.set_runtime_manifest (session ()) spec;
        (match field fields "schedule" with
         | None -> ()
         | Some schedule when not (Session.schedule_locked (session ())) ->
             let scheduler = Session.scheduler (session ()) in
             let fields = map_fields schedule in
             let kind = string_field fields "kind" in
             let handler = if kind = "custom" then custom_scheduler schedule else
               let policy = runtime_schedule schedule in
               Scheduler.builtin
                 ~remote_dispatch:(match Session.remote_dispatch (session ()) with
                   | Some dispatch -> dispatch
                   | None -> (fun ~member:_ _ ->
                       failwith "configure-runtime: remote schedules require a host configuration"))
                 policy in
             Scheduler.install scheduler handler;
             Dynamic_scope.record_event (VMap [
               VKeyword "kind", VKeyword "runtime-schedule";
               VKeyword "handler", VString (Scheduler.handler_name handler)
             ])
         | Some _ -> ());
        (match field fields "reporter" with
         | Some reporter ->
             (match reporter with
              | VClosure _ | VBuiltin _ ->
                  Session.register_reporter (session ()) reporter
              | value -> failwith ("runtime manifest :reporter expects a function, got " ^
                  Presentation.string_of_value value))
         | None -> ());
        VNil
    | _ -> failwith "configure-runtime expects one map argument");

  register "runtime-config" (fun args _env ->
    Dynamic_scope.require_script_tier
      "runtime-config: may not be called inside a node body (scripting-tier only)";
    match args with
    | [] -> Option.value ~default:(VMap []) (Session.runtime_manifest (session ()))
    | _ -> failwith "runtime-config expects no arguments");

  register "register-reporter" (fun args _env ->
    if Effect.perform Dynamic_scope.In_node then
      failwith "register-reporter: may not be called inside a node body";
    match args with
    | [reporter] ->
        (match force_val reporter with
         | (VClosure _ | VBuiltin _) as value ->
             Session.register_reporter (session ()) value; VNil
         | value -> failwith ("register-reporter expects a function, got " ^
             Presentation.string_of_value value))
    | _ -> failwith "register-reporter expects one function");

  register "emit-event" (fun args _env ->
    if Effect.perform Dynamic_scope.In_node then
      failwith "emit-event: may not be called inside a node body";
    match args with
    | [event] -> Dynamic_scope.record_event (force_val event); VNil
    | _ -> failwith "emit-event expects one event map");

  (* ---- fenced: register a non-convergent action for reconciliation.
     It may not appear inside a node body. The action is not
     executed during evaluation; the active reconciler drains it after
     convergent state is applied. *)
  register "fenced" (fun args _env ->
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
     pattern Fenced.register uses): ordinary primitive, root/script
     scope. `:write-cap` is consumed into the session's domain registry, never
     re-exposed to user code — the core-side registry IS the authority
     boundary. `:diff`/`:apply` are REQUIRED for a full domain (a domain
     with ⊥ write authority is a PROBE — register-probe below, a distinct,
     simpler entry point); `:namespace` is a list of cell-id string
     PREFIXES this domain owns (stratification);
     `:observe-cell` is optional. Returns nil. *)
  register "register-domain" (fun args _env ->
    if Effect.perform Dynamic_scope.In_node then
      failwith "register-domain: may not be called inside a node body (script-tier only, like fenced)";
    match args with
    | [spec] ->
        (match Domain_config.decode_domain ~force:force_val spec with
         | Ok registration ->
             Session.register_domain (Effect.perform Dynamic_scope.Get_session)
               registration.name registration.entry;
             VNil
         | Error message -> failwith message)
    | _ -> failwith "register-domain expects one map argument");

  (* `(register-probe name observe-fn read-cap)` — sugar over register-domain
     for the ⊥-write-authority case: dm_namespace = [] (nothing to
     stratify, core never converges it), dm_diff/dm_apply = None. Same
     surface and error text as a standalone probe registry. *)
  register "register-probe" (fun args _env ->
    if Effect.perform Dynamic_scope.In_node then
      failwith "register-probe: may not be called inside a node body (script-tier only, like fenced)";
    match args with
    | [name; observe; capability] ->
        (match Domain_config.decode_probe ~force:force_val name observe capability with
         | Ok registration ->
             Session.register_probe (Effect.perform Dynamic_scope.Get_session)
               registration.name registration.entry;
             VNil
         | Error message -> failwith message)
    | _ -> failwith "register-probe expects a name, an observe-fn, and a read capability");
  (* ---- `probe` primitive: one-time evaluated lazy read of a registered probe ----
     a pass evaluates observe-fn (via Observation.probe_value, above: OUTSIDE the
     trace stack, under exactly the registered read-cap) and pins the
     result in the session for the rest of the pass; every read
     (first or not) records ONLY the `probe:<name>` cell into the caller's
     trace, via the Observation.record path every other cell-observing
     primitive uses (slurp's `file:`, env-get's `env:`, …) — capability-free
     at THIS call site, because the read-cap's authority was already spent
     evaluating the probe, not reading its pinned result. An unregistered
     name is a hard error naming it, on every read (never silently nil). *)
  register "probe" (fun args _env ->
    let args = force_args args in
    match args with
    | [VString name] | [VKeyword name] ->
        (match Observation.probe_value name with
         | None -> failwith ("probe: no such probe registered: " ^ name)
         | Some v ->
             Observation.record (Cell.Probe name) (Identity.hash_value v);
             v)
    | _ -> failwith "probe expects a probe name string");
  ()

let register_collect_and_sealed () =
  let register = register ~category:Diagnostics in
  (* ---- collect: applicative/validation error-accumulation partition ---- *)

  (* `collect(items)` — partition a list of `[:ok, v]` / `[:err, e]` results.
     Returns `[:ok, values]` if all succeeded, `[:err, errors]` if any failed.
     A plain function used in pipelines (`srcs |> map(f) |> collect`); the
     validation counterpart to `try`'s short-circuit monad. Was the
     `collect-results` primitive behind the removed `collect { }` reader sugar. *)
  register "collect" (fun args _env ->
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
                        ^ Presentation.string_of_value other)
        in
        partition items [] []
    | _ -> failwith "collect expects one argument");
  (* ---- Sealed cells ---- *)

  (* `(unseal v)` — the one sanctioned way out of VSealed to VString (the
     explicit, greppable Vault/SOPS-style boundary; derived data is ordinary
     data afterward — no dataflow tainting, by design). Anything else is a
     hard error naming the mistake. *)
  register "unseal" (fun args _env ->
    match args with
    | [arg] ->
        (match force_val arg with
         | VSealed bytes -> VString bytes
         | other -> failwith ("unseal expects a sealed value, got " ^ Presentation.string_of_value other))
    | _ -> failwith "unseal expects one argument");
  ()

let register_macros () =
  let register = register ~category:Metaprogramming in
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

  register "quasiquote" (fun args _env ->
    let args = force_args args in
    match args with
    | [v] -> quasiquote_walk v
    | _ -> failwith "quasiquote expects one argument"
  );

  register "unquote" (fun _ _env ->
    failwith "unquote not allowed outside quasiquote"
  );

  register "unquote-splicing" (fun _ _env ->
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
  register "gensym" (fun args _env ->
    Dynamic_scope.require_script_tier
      "gensym: may not be called inside a node body (scripting-tier only)";
    let prefix = match force_args args with
      | [] -> "g"
      | [VString p] -> p
      | [VSymbol p] -> p
      | _ -> failwith "gensym expects an optional string/symbol prefix"
    in
    let n = Session.next_gensym (Effect.perform Dynamic_scope.Get_session) in
    VSymbol (Printf.sprintf "%s~%d" prefix n));
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
  List.iter (fun name ->
    Primitive_catalog.alias catalog ~alias:("\000" ^ name) ~target:name)
    ["car"; "cdr"; "="; "nil?"; "not"; "error"; "pair?"]

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
  register_macros ();
  register_match_aliases ();
  Primitive_catalog.finalize catalog

let render_catalog () =
  Primitive_catalog.render catalog
