(* pp primitives — built-in functions *)

open Types

(* Reference to the evaluator's force function — set by evaluator at init *)
let force_ref : (value -> value) ref = ref (fun v -> v)
let set_force (f : value -> value) = force_ref := f

(* Reference to the current environment — updated by evaluator at eval entry *)
let current_env_ref : env ref = ref Types.empty_env

(* References to evaluator's eval and apply — set by evaluator at init *)
let eval_ref : (expr -> env -> value) ref = ref (fun _ _ -> failwith "eval not initialized")
let apply_ref : (value -> value list -> env -> value) ref = ref (fun _ _ _ -> failwith "apply not initialized")
let set_eval (f : expr -> env -> value) = eval_ref := f
let set_apply (f : value -> value list -> env -> value) = apply_ref := f

(* Reference to the VM's thunk runner — set by VM at init *)
let vm_run_thunk_ref : (Types.bytecode -> int -> Types.frame list -> Types.value) ref =
  ref (fun _ _ _ -> failwith "VM not initialized")

(* Force helpers for builtins *)
let force_val (v : value) : value = !force_ref v
let force_args (args : value list) : value list = List.map force_val args
let force_one (v : value) : value = force_val v

(* Deep force: recursively force all thunks in a data structure *)
let rec force_deep (v : value) : value =
  match force_val v with
  | VPair (car, cdr) -> VPair (force_deep car, force_deep cdr)
  | VVector vs -> VVector (Array.map force_deep vs)
  | VMap kvs -> VMap (List.map (fun (k, v) -> (force_deep k, force_deep v)) kvs)
  | VSet vs -> VSet (List.map force_deep vs)
  | other -> other

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


(* Refs for compiler primitives — set by Compiler.init_primitives after compiler.ml loads *)
let compiler_state_ref : Types.comp_state option ref = ref None
let compiler_finish_ref : (Types.comp_state -> Types.bytecode) ref =
  ref (fun _ -> failwith "compiler not initialized")

(* Ref for VM bytecode runner — set by Vm.init after vm.ml loads *)
let vm_run_bytecode_ref : (Types.bytecode -> Types.value) ref =
  ref (fun _ -> failwith "VM not initialized")

(* Ref for VM global definition hook — set by Vm.init after vm.ml loads.
   Used by eval-pp so that definitions it returns are visible to the VM. *)
let vm_define_ref : (string -> Types.value -> unit) ref =
  ref (fun _ _ -> ())
let () =
  (* Arithmetic — strict: force all args, variadic + and * with identity *)
  register "+" (fun args ->
    let args = force_args args in
    match args with
    | [] -> VInt 0
    | _ ->
        let rec add acc = function
          | [] -> acc
          | VInt n :: rest -> add (match acc with VInt a -> VInt (a + n) | VFloat a -> VFloat (a +. float_of_int n)) rest
          | VFloat f :: rest -> add (match acc with VInt a -> VFloat (float_of_int a +. f) | VFloat a -> VFloat (a +. f)) rest
          | v :: _ -> failwith (Printf.sprintf "+ expects numbers, got %s" (string_of_value v))
        in
        add (List.hd args) (List.tl args));

  register "-" (fun args ->
    let args = force_args args in
    match args with
    | [VInt a; VInt b] -> VInt (a - b)
    | [VFloat a; VFloat b] -> VFloat (a -. b)
    | _ -> failwith "- expects two numbers");

  register "*" (fun args ->
    let args = force_args args in
    match args with
    | [] -> VInt 1
    | _ ->
        let rec mul acc = function
          | [] -> acc
          | VInt n :: rest -> mul (match acc with VInt a -> VInt (a * n) | VFloat a -> VFloat (a *. float_of_int n)) rest
          | VFloat f :: rest -> mul (match acc with VInt a -> VFloat (float_of_int a *. f) | VFloat a -> VFloat (a *. f)) rest
          | v :: _ -> failwith (Printf.sprintf "* expects numbers, got %s" (string_of_value v))
        in
        mul (List.hd args) (List.tl args));

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

  register "<" (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | _ ->
        let rec chained = function
          | [] | [_] -> true
          | VInt a :: VInt b :: rest -> a < b && chained (VInt b :: rest)
          | VFloat a :: VFloat b :: rest -> a < b && chained (VFloat b :: rest)
          | VInt a :: VFloat b :: rest -> float_of_int a < b && chained (VFloat b :: rest)
          | VFloat a :: VInt b :: rest -> a < float_of_int b && chained (VInt b :: rest)
          | _ -> failwith "< expects numbers"
        in
        VBool (chained args));

  register ">" (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | _ ->
        let rec chained = function
          | [] | [_] -> true
          | VInt a :: VInt b :: rest -> a > b && chained (VInt b :: rest)
          | VFloat a :: VFloat b :: rest -> a > b && chained (VFloat b :: rest)
          | VInt a :: VFloat b :: rest -> float_of_int a > b && chained (VFloat b :: rest)
          | VFloat a :: VInt b :: rest -> a > float_of_int b && chained (VInt b :: rest)
          | _ -> failwith "> expects numbers"
        in
        VBool (chained args));

  register "<=" (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | _ ->
        let rec chained = function
          | [] | [_] -> true
          | VInt a :: VInt b :: rest -> a <= b && chained (VInt b :: rest)
          | VFloat a :: VFloat b :: rest -> a <= b && chained (VFloat b :: rest)
          | VInt a :: VFloat b :: rest -> float_of_int a <= b && chained (VFloat b :: rest)
          | VFloat a :: VInt b :: rest -> a <= float_of_int b && chained (VInt b :: rest)
          | _ -> failwith "<= expects numbers"
        in
        VBool (chained args));

  register ">=" (fun args ->
    let args = force_args args in
    match args with
    | [] | [_] -> VBool true
    | _ ->
        let rec chained = function
          | [] | [_] -> true
          | VInt a :: VInt b :: rest -> a >= b && chained (VInt b :: rest)
          | VFloat a :: VFloat b :: rest -> a >= b && chained (VFloat b :: rest)
          | VInt a :: VFloat b :: rest -> float_of_int a >= b && chained (VFloat b :: rest)
          | VFloat a :: VInt b :: rest -> a >= float_of_int b && chained (VInt b :: rest)
          | _ -> failwith ">= expects numbers"
        in
        VBool (chained args));

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
      | k :: v :: rest -> (force_one k, v) :: make_pairs rest
      | _ -> failwith "hash-map expects even number of arguments"
    in
    VMap (make_pairs args));  (* keys forced, values lazy *)

  register "hash-map-get" (fun args ->
    let args = force_args args in
    match args with
    | [VMap kvs; key] ->
        (match List.find_opt (fun (k, _) -> force_one k = key) kvs with
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
    | [arg] -> VBool (match force_one arg with VBool b -> not b | VNil -> true | _ -> false)
    | _ -> failwith "not expects one argument");

  register "error" (fun args ->
    let args = force_args args in
    match args with
    | [VString msg] -> failwith msg
    | _ -> failwith "error");


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

  (* ---- eval-pp and apply-pp ---- *)

  register "eval-pp" (fun args ->
    let args = force_args args in
    match args with
    | [VString code] ->
        let exprs = Reader.read_string code in
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
              !vm_define_ref name closure;
              new_defs := (name, closure) :: !new_defs;
              if !new_defs = [] then VNil else VEnvMap (List.rev !new_defs)
          | [last] ->
              (* Pure expression: evaluate and force *)
              force_one (!eval_ref last !local_env)
          | (ELocated (_, inner)) :: rest -> go (inner :: rest)
          | (EDef (name, params, body)) :: rest ->
              let closure = Types.make_closure ~name:(Some name) params body local_env in
              local_env := Types.extend_env !local_env name closure;
              !vm_define_ref name closure;
              new_defs := (name, closure) :: !new_defs;
              go rest
          | e :: rest ->
              ignore (force_one (!eval_ref e !local_env));
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
        (match fn with
         | VClosure c when Array.length c.vm_bc.code > 0 ->
             let new_frame = Types.make_frame (List.length c.params) in
             List.iteri (fun i arg -> Types.frame_set new_frame i arg) arg_values;
             !vm_run_thunk_ref c.vm_bc c.vm_offset (new_frame :: c.vm_frames)
         | _ ->
             !apply_ref fn arg_values !current_env_ref)
    | _ -> failwith "apply-pp expects fn and list of args"
  );

  (* ---- force-deep ---- *)

  register "force-deep" (fun args ->
    let args = force_args args in
    match args with
    | [v] -> force_deep v
    | _ -> failwith "force-deep expects one argument"
  );

  (* ---- slurp: read file to string ---- *)

  register "slurp" (fun args ->
    let args = force_args args in
    match args with
    | [VString path] ->
        if not (List.exists (fun cap -> Capabilities.check_fs_read cap path) !Runtime.current_capabilities) then
          failwith ("slurp: permission denied for " ^ path);
        (try
           let ch = open_in path in
           let content = really_input_string ch (in_channel_length ch) in
           close_in ch;
           VString content
         with Sys_error msg -> failwith ("slurp: " ^ msg))
    | _ -> failwith "slurp expects a file path string"
  );

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

  (* ---- island-fetch: resolve a remote island URI to a local path ---- *)
  register "island-fetch" (fun args ->
    let args = force_args args in
    match args with
    | [VString uri] -> VString uri
    | _ -> failwith "island-fetch expects a URI string"
  );


  register "ppc-emit-opcode" (fun args ->
    let args = force_args args in
    failwith "ppc-emit-opcode: not yet implemented for self-hosting"
  );

  register "ppc-emit-constant" (fun args ->
    let args = force_args args in
    failwith "ppc-emit-constant: not yet implemented for self-hosting"
  );

  register "ppc-finish" (fun args ->
    match !compiler_state_ref with
    | Some st ->
        compiler_state_ref := None;
        let bc = !compiler_finish_ref st in
        Types.VBytecode bc
    | None ->
        failwith "ppc-finish: no active compiler state"
  );

  register "ppc-run" (fun args ->
    let args = force_args args in
    match args with
    | [Types.VBytecode bc] ->
        !vm_run_bytecode_ref bc
    | _ -> failwith "ppc-run expects a bytecode value"
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

  ()
