(* pp primitives — built-in functions *)

open Types

(* Reference to the evaluator's force function — set by evaluator at init *)
let force_ref : (value -> value) ref = ref (fun v -> v)
let set_force (f : value -> value) = force_ref := f

(* Force helpers for builtins *)
let force_val (v : value) : value = !force_ref v
let force_args (args : value list) : value list = List.map force_val args
let force_one (v : value) : value = force_val v

(* A table of built-in functions: name -> value *)
let builtins : (string, value) Hashtbl.t = Hashtbl.create 64

let register (name : string) (f : value list -> value) : unit =
  Hashtbl.add builtins name (VBuiltin (name, f))

let lookup (name : string) : value option =
  Hashtbl.find_opt builtins name

let initial_env () : env =
  let bindings = Hashtbl.fold (fun name v acc -> (name, v) :: acc) builtins [] in
  env_of_bindings bindings

(* ---- Register all primitives ---- *)

let () =
  (* Arithmetic — strict: force all args *)
  register "+" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a + b)
    | [VFloat a; VFloat b] -> VFloat (a +. b)
    | [VInt a; VFloat b] -> VFloat (float_of_int a +. b)
    | [VFloat a; VInt b] -> VFloat (a +. float_of_int b)
    | _ -> failwith "+ expects two numbers");

  register "-" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a - b)
    | [VFloat a; VFloat b] -> VFloat (a -. b)
    | _ -> failwith "- expects two numbers");

  register "*" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a * b)
    | [VFloat a; VFloat b] -> VFloat (a *. b)
    | _ -> failwith "* expects two numbers");

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

  (* Comparison — strict *)
  register "=" (fun args ->
    let args = force_args args in
    match args with
    | [a; b] -> VBool (try a = b with Invalid_argument _ -> a == b)
    | _ -> failwith "= expects two arguments");

  register "<" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VBool (a < b)
    | [VFloat a; VFloat b] -> VBool (a < b)
    | _ -> failwith "< expects two numbers");

  register ">" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VBool (a > b)
    | [VFloat a; VFloat b] -> VBool (a > b)
    | _ -> failwith "> expects two numbers");

  register "<=" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VBool (a <= b)
    | [VFloat a; VFloat b] -> VBool (a <= b)
    | _ -> failwith "<= expects two numbers");

  register ">=" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VBool (a >= b)
    | [VFloat a; VFloat b] -> VBool (a >= b)
    | _ -> failwith ">= expects two numbers");

  (* List operations — car/cdr force the pair, cons/list are lazy *)
  register "cons" (fun args ->
    match args with
    | [a; b] -> VPair (a, b)  (* lazy: stores thunks *)
    | _ -> failwith "cons expects two arguments");

  register "car" (fun args ->
    match args with
    | [arg] ->
        (match force_one arg with
         | VPair (a, _) -> a  (* return car as-is, may be thunk *)
         | VNil -> VNil
         | _ -> failwith "car expects a pair")
    | _ -> failwith "car expects one argument");

  register "cdr" (fun args ->
    match args with
    | [arg] ->
        (match force_one arg with
         | VPair (_, d) -> d  (* return cdr as-is *)
         | VNil -> VNil
         | _ -> failwith "cdr expects a pair")
    | _ -> failwith "cdr expects one argument");

  register "list" (fun args ->
    List.fold_right (fun a acc -> VPair (a, acc)) args VNil);  (* lazy *)

  register "nil?" (fun args ->
    match args with
    | [arg] -> VBool (match force_one arg with VNil -> true | _ -> false)
    | _ -> failwith "nil? expects one argument");

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
      | k :: v :: rest -> (k, v) :: make_pairs rest
      | _ -> failwith "hash-map expects even number of arguments"
    in
    VMap (make_pairs args));  (* lazy *)

  register "hash-map-get" (fun args ->
    let args = force_args args in
    match args with
    | [VMap kvs; key] ->
        (match List.find_opt (fun (k, _) -> k = key) kvs with
         | Some (_, v) -> v
         | None -> VNil)
    | _ -> failwith "hash-map-get expects a map and a key");

  (* Set operations *)
  register "hash-set" (fun args ->
    VSet args);  (* lazy *)

  (* Type predicates — force to check *)
  register "int?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VInt _ -> true | _ -> false) | _ -> failwith "int? expects one arg");
  register "float?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VFloat _ -> true | _ -> false) | _ -> failwith "float? expects one arg");
  register "string?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VString _ -> true | _ -> false) | _ -> failwith "string? expects one arg");
  register "bool?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VBool _ -> true | _ -> false) | _ -> failwith "bool? expects one arg");
  register "keyword?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VKeyword _ -> true | _ -> false) | _ -> failwith "keyword? expects one arg");
  register "symbol?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VSymbol _ -> true | _ -> false) | _ -> failwith "symbol? expects one arg");
  register "pair?" (fun args ->
    match args with [arg] -> (match force_one arg with VPair _ -> VBool true | VNil -> VBool true | _ -> VBool false) | _ -> failwith "pair? expects one arg");
  register "vector?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VVector _ -> true | _ -> false) | _ -> failwith "vector? expects one arg");
  register "map?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VMap _ -> true | _ -> false) | _ -> failwith "map? expects one arg");
  register "set?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VSet _ -> true | _ -> false) | _ -> failwith "set? expects one arg");
  register "fn?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VClosure _ | VBuiltin _ -> true | _ -> false) | _ -> failwith "fn? expects one arg");
  register "thunk?" (fun args ->
    match args with [arg] -> VBool (match arg with VThunk _ -> true | _ -> false) | _ -> failwith "thunk? expects one arg");

  (* I/O — strict *)
  register "print" (fun args ->
    let args = force_args args in
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
    | [arg] -> VBool (match force_one arg with VBool b -> not b | VNil -> true | _ -> false)
    | _ -> failwith "not expects one argument");

  register "error" (fun args ->
    let args = force_args args in
    match args with
    | [VString msg] -> failwith msg
    | _ -> failwith "error");

  (* Capability constructors *)
  register "filesystem" (fun args ->
    let args = force_args args in
    match args with
    | [VString path; VKeyword mode] ->
        let m = match mode with
          | "ro" -> Read | "rw" -> ReadWrite | "wo" -> Write
          | _ -> failwith "filesystem mode must be :ro, :rw, or :wo"
        in
        VCapability (CapFilesystem { path; mode = m })
    | _ -> failwith "filesystem expects path string and mode keyword");

  register "network" (fun args ->
    let args = force_args args in
    match args with
    | [VKeyword protocol] ->
        let p = match protocol with
          | "tcp" -> "tcp" | "udp" -> "udp" | "any" -> "any"
          | _ -> failwith "network protocol must be :tcp, :udp, or :any"
        in
        VCapability (CapNetwork { protocol = p })
    | _ -> failwith "network expects a protocol keyword");

  register "process" (fun args ->
    match args with [] -> VCapability CapProcess | _ -> failwith "process takes no arguments");

  register "time-budget" (fun args ->
    let args = force_args args in
    match args with [VInt ms] -> VCapability (CapTime ms) | _ -> failwith "time-budget expects ms integer");

  register "memory-budget" (fun args ->
    let args = force_args args in
    match args with [VInt bytes] -> VCapability (CapMemory bytes) | _ -> failwith "memory-budget expects bytes integer");

  register "cap-compose" (fun args ->
    let caps = List.map (fun v -> match force_one v with VCapability c -> c | _ -> failwith "cap-compose expects capabilities") args in
    VCapability (CapCompose caps));

  register "cap-restrict" (fun args ->
    let args = force_args args in
    match args with
    | [VCapability cap; VString scope] -> VCapability (CapRestrict { cap; scope })
    | _ -> failwith "cap-restrict expects a capability and a scope string");

  register "cap-none" (fun args ->
    match args with [] -> VCapability CapNone | _ -> failwith "cap-none takes no arguments");

  register "capability?" (fun args ->
    match args with [arg] -> VBool (match force_one arg with VCapability _ -> true | _ -> false) | _ -> failwith "capability? expects one arg");

  ()
