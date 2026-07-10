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
  let h = hash_concat ["thunk"; Hasher.hash_expr expr; env.env_hash; caps_hash; cfg_hash] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = None; thunk_loc = None; config_hash = cfg_hash } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Like make_thunk_ca, but the thunk carries a type annotation that is
   checked when the thunk is forced (mirrors the VM's MAKE_THUNK with
   type_ann, vm.ml). The annotation participates in the content hash so a
   typed thunk is never conflated with an untyped thunk over the same expr. *)
let make_thunk_ca_typed (expr : expr) (ty : expr) (loc : (string * int) option) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
  let h = hash_concat ["thunk-typed"; Hasher.hash_expr expr; Hasher.hash_expr ty; env.env_hash; caps_hash; cfg_hash] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env; vm_code = None; type_ann = Some ty; thunk_loc = loc; config_hash = cfg_hash } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* Runtime check for gradual type annotations. This mirrors the VM's
   check_type (vm.ml) EXACTLY — same recognized type names, same
   "unknown types pass" policy, same error message — so both backends
   fail identically. Keep the two in sync. *)
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
           force result
       | Evaluating ->
           decr force_depth;
           failwith "infinite recursion detected (forcing a thunk already being evaluated)"
       | Unevaluated ->
           t.thunk_status <- Evaluating;
           let result =
             match t.vm_code with
             | Some (bc, code_offset, frames) ->
                 !Primitives.vm_run_thunk_ref bc code_offset frames
             | None ->
                 eval t.thunk_expr t.thunk_env
           in
           (match t.type_ann with
            | Some ty -> check_type result ty t.thunk_loc
            | None -> ());
           t.thunk_status <- Evaluated result;
           decr force_depth;
           force result)
  | _ ->
      decr force_depth;
      v

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
      k (make_thunk_ca e env)

  | EDefNode (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

  | EDo exprs ->
      (* All but last are non-tail; last is tail.
         Uses a local env ref for threading — NOT current_env_ref,
         because inner evaluations would clobber it. *)
      let env_ref = ref env in
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
        | (EImport mod_expr) :: rest ->
            let mod_val = force (eval mod_expr !env_ref) in
            (match mod_val with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 go rest
             | _ -> failwith "import expects a module value")
        | (ELoad path) :: rest ->
            let ch = open_in path in
            let source = really_input_string ch (in_channel_length ch) in
            close_in ch;
            let exprs = Reader.read_string source in
            ignore (eval_expressions exprs env_ref);
            go rest
        | (ELoadModule path) :: rest ->
            let ch = open_in path in
            let source = really_input_string ch (in_channel_length ch) in
            close_in ch;
            let exprs = Reader.read_string source in
            let mod_ref = ref (Primitives.initial_env ()) in
            ignore (eval_expressions exprs mod_ref);
            let base_bindings = (Primitives.initial_env ()).bindings in
            let rec collect_new all parent acc =
              match all with
              | [] -> List.rev acc
              | (n, v) :: rest ->
                  if List.exists (fun (pn, _) -> pn = n) parent then
                    collect_new rest parent acc
                  else
                    collect_new rest parent ((n, v) :: acc)
            in
            let mod_val = VEnvMap (collect_new (!mod_ref).bindings base_bindings []) in
            (match mod_val with
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

  | EEffect (caps_expr, body) ->
      let caps_val = force (eval caps_expr env) in
      let caps =
        match caps_val with
        | VNil -> []
        | _ -> extract_capabilities caps_val
      in
      let saved_caps = !current_capabilities in
      current_capabilities := caps @ saved_caps;
      let result = eval_tail body env k in
      current_capabilities := saved_caps;
      result

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      k (perform_effect name forced_args)

  | EWithHandler (handlers, body) ->
      let saved_handlers = !handler_stack in
      let new_handlers = List.map (fun (name, handler_expr) ->
        let handler_val = force (eval handler_expr env) in
        (name, fun args ->
          apply handler_val args env)
      ) handlers in
      handler_stack := new_handlers @ saved_handlers;
      let result = eval_tail body env k in
      handler_stack := saved_handlers;
      result

  | EDef (name, params, body) ->
      k (make_closure ~name:(Some name) params body (ref env))

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
      let final_env = List.fold_left (fun (env_acc : env) e ->
        match e with
        | EDef (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefNode (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
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
      let rec collect_new all parent acc =
        match all with
        | [] -> List.rev acc
        | (n, v) :: rest ->
            if List.exists (fun (pn, _) -> pn = n) parent then
              collect_new rest parent acc
            else
              collect_new rest parent ((n, v) :: acc)
      in
      let new_bindings = collect_new final_env.bindings base_env.bindings [] in
      k (VEnvMap new_bindings)

  | EImport mod_expr ->
      let mod_val = force (eval mod_expr env) in
      k mod_val

  | ELoad path ->
      let ch = open_in path in
      let source = really_input_string ch (in_channel_length ch) in
      close_in ch;
      let exprs = Reader.read_string source in
      let env_ref = ref env in
      k (eval_expressions exprs env_ref)

  | ELoadModule path ->
      let ch = open_in path in
      let source = really_input_string ch (in_channel_length ch) in
      close_in ch;
      let exprs = Reader.read_string source in
      let mod_ref = ref (Primitives.initial_env ()) in
      ignore (eval_expressions exprs mod_ref);
      let base_bindings = (Primitives.initial_env ()).bindings in
      let rec collect_new all parent acc =
        match all with
        | [] -> List.rev acc
        | (n, v) :: rest ->
            if List.exists (fun (pn, _) -> pn = n) parent then
              collect_new rest parent acc
            else
              collect_new rest parent ((n, v) :: acc)
      in
      k (VEnvMap (collect_new (!mod_ref).bindings base_bindings []))

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
  | EIsland (uri, _) ->
      let ch = open_in uri in
      let source = really_input_string ch (in_channel_length ch) in
      close_in ch;
      let exprs = Reader.read_string source in
      let env_ref = ref env in
      k (eval_expressions exprs env_ref)
  | EWithConfig (map_expr, body) ->
      let cfg = force (eval map_expr env) in
      (match cfg with
       | VMap _ ->
           let saved = !config_stack in
           config_stack := cfg :: !config_stack;
           let result = eval_tail body env k in
           config_stack := saved;
           result
       | _ -> failwith "with-config expects a map")
  | EConfig (key_expr, default_opt) ->
      let key_val = force (eval key_expr env) in
      let key_name = match key_val with
        | VString s | VKeyword s | VSymbol s -> s
        | _ -> failwith "config key must be a string, keyword, or symbol" in
      let rec find = function
        | [] -> None
        | VMap kvs :: rest ->
            (match List.assoc_opt (VString key_name) kvs with
             | Some v -> Some v
             | None ->
                 (match List.assoc_opt (VKeyword key_name) kvs with
                  | Some v -> Some v
                  | None -> find rest))
        | _ :: rest -> find rest
      in
      (match find !config_stack with
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
  | VClosure { fn_name = _; params; body; env = closure_env; _ } ->
      if List.length params <> List.length args then
        failwith (Printf.sprintf "arity mismatch: expected %d args, got %d"
                    (List.length params) (List.length args));
      let env' = List.fold_left2 (fun e param arg ->
        extend_env e param arg  (* arg is already a thunk *)
      ) !closure_env params args in
      eval_tail body env' k

  | VBuiltin (name, f) ->
      Primitives.current_env_ref := env;
      let forced_args = List.map (fun v ->
        match v with VThunk _ -> v | _ -> v
      ) args in
      k (try f forced_args
         with Failure msg ->
           failwith (Printf.sprintf "builtin '%s' failed: %s" name msg))

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
        match v with
        | VThunk t ->
            (match t.thunk_status with
             | Evaluated result -> Queue.add result queue; loop ()
             | Evaluating -> failwith "infinite recursion detected (trampoline)"
             | Unevaluated ->
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
                 loop ())
        | _ -> v  (* non-thunk: done *)
  in
  loop ()
(* ---- Effect System ---- *)

and perform_effect (name : string) (args : value list) : value =
  (* Check for handler *)
  let rec find_handler = function
    | [] ->
        (* No handler — try builtin effect *)
        perform_builtin_effect name args
    | (n, handler) :: rest ->
        if n = name then handler args
        else find_handler rest
  in
  find_handler !handler_stack

and perform_builtin_effect (name : string) (args : value list) : value =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           if not (has_fs_read path) then
             failwith ("capability error: no read access for " ^ path);
           (try
              let ch = open_in path in
              let content = really_input_string ch (in_channel_length ch) in
              close_in ch;
              VString content
            with Sys_error msg -> failwith ("read-file: " ^ msg))
       | _ -> failwith "read-file expects a string path")

  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           if not (has_fs_write path) then
             failwith ("capability error: no write access for " ^ path);
           (try
              let ch = open_out path in
              output_string ch content;
              close_out ch;
              VNil
            with Sys_error msg -> failwith ("write-file: " ^ msg))
       | _ -> failwith "write-file expects path and content strings")

  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg;
           VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg;
           VNil
       | _ -> failwith "log expects a message string")

  | "random" ->
      VInt (Random.int max_int)

  | _ ->
      failwith ("unhandled effect: " ^ name)

(* ---- Helpers ---- *)

and has_fs_read (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_read cap path) !current_capabilities

and has_fs_write (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_write cap path) !current_capabilities

and extract_capabilities (v : value) : capability list =
  match v with
  | VCapability c -> [c]
  | VVector vs -> Array.to_list (Array.map (fun v ->
      match force v with VCapability c -> c | _ -> failwith "capability vector must contain capabilities"
    ) vs)
  | VPair _ ->
      let rec collect acc = function
        | VNil -> List.rev acc
        | VPair (v, rest) ->
            (match force v with
             | VCapability c -> collect (c :: acc) rest
             | other -> failwith ("not a capability: " ^ string_of_value other))
        | _ -> failwith "capability list must be a proper list"
      in
      collect [] v
  | _ -> failwith ("expected capability, got: " ^ string_of_value v)


(* Evaluate expressions sequentially with mutable env — used by ELoad, ELoadModule, and REPL *)
and eval_expressions (exprs : expr list) (env : env ref) : value =
  let unwrap e = match e with ELocated (_, e') -> e' | _ -> e in
  let rec go = function
    | [] -> VNil
    | [e] ->
        (match unwrap e with
         | EDef (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             closure
         | EDefNode (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             closure
         | EImport mod_expr ->
             let mod_val = force (eval e !env) in
             (match mod_val with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  mod_val
              | _ -> failwith "import expects a module value")
         | ELoad path ->
             let ch = open_in path in
             let source = really_input_string ch (in_channel_length ch) in
             close_in ch;
             let exprs = Reader.read_string source in
             eval_expressions exprs env
         | _ ->
             let result = force (eval e !env) in
             (match result with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  result
              | _ -> result))
    | e :: rest ->
        (match unwrap e with
         | EDef (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             go rest
         | EDefNode (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             go rest
         | EImport mod_expr ->
             let mod_val = force (eval e !env) in
             (match mod_val with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  go rest
              | _ -> failwith "import expects a module value")
         | ELoad path ->
             let ch = open_in path in
             let source = really_input_string ch (in_channel_length ch) in
             close_in ch;
             let exprs = Reader.read_string source in
             ignore (eval_expressions exprs env);
             go rest
         | _ ->
             let result = force (eval e !env) in
             (match result with
              | VEnvMap bindings ->
                  env := List.fold_left (fun env' (n, v) ->
                    extend_env env' n v) !env bindings;
                  go rest
              | _ -> go rest))
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
  Hashtbl.clear thunk_store;
  Primitives.set_force force;
  Primitives.set_eval eval;
  Primitives.set_apply apply
