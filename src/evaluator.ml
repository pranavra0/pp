(* pp evaluator — lazy, call-by-need evaluator with thunks *)

open Types
open Hasher

(* ---- Evaluation State ---- *)

(* Handler stack for algebraic effects *)
let handler_stack : (string * (value list -> value)) list ref = ref []

(* Current capability set (for effectful blocks) *)
let current_capabilities : capability list ref = ref []

(* Content-addressed thunk store: hash -> thunk record *)
let thunk_store : (string, thunk) Hashtbl.t = Hashtbl.create 1024

(* Create or retrieve a content-addressed thunk.
   Two thunks with the same (expr, env, capabilities) are the SAME thunk.
   Uses env.env_hash for O(1) environment identity — no recursive traversal. *)
let make_thunk_ca (expr : expr) (env : env) : value =
  let caps_hash = hash_concat ("caps" :: List.map Hasher.hash_capability !current_capabilities) in
  let h = hash_concat ["thunk"; Hasher.hash_expr expr; env.env_hash; caps_hash] in
  match Hashtbl.find_opt thunk_store h with
  | Some existing -> VThunk existing
  | None ->
      let t = { thunk_status = Unevaluated; thunk_hash = Some h; thunk_expr = expr; thunk_env = env } in
      Hashtbl.add thunk_store h t;
      VThunk t

(* ---- Force: evaluate a thunk on demand ---- *)

let rec force (v : value) : value =
  match v with
  | VThunk t ->
      (match t.thunk_status with
       | Evaluated result -> force result
       | Evaluating -> failwith "infinite recursion detected (forcing a thunk already being evaluated)"
       | Unevaluated ->
           t.thunk_status <- Evaluating;
           let result = eval t.thunk_expr t.thunk_env in
           t.thunk_status <- Evaluated result;
           force result)
  | _ -> v

(* ---- Main Evaluator ---- *)

and eval (e : expr) (env : env) : value =
  match e with
  | ELiteral v -> v  (* self-evaluating *)

  | ESymbol name ->
      (match lookup_env env name with
       | Some v -> force v  (* force bindings on access *)
       | None ->
           (match Primitives.lookup name with
            | Some v -> v
            | None -> failwith ("unbound symbol: " ^ name)))

  | EIf (cond, then_e, else_e) ->
      (* Force the condition to decide which branch *)
      (match force (eval cond env) with
       | VBool true -> eval then_e env
       | VBool false -> eval else_e env
       | VNil -> eval else_e env  (* nil is falsy *)
       | _ -> eval then_e env)     (* non-nil, non-false is truthy *)

  | ELet (bindings, body) ->
      (* Create thunks for each binding — DON'T force them *)
      let env' = List.fold_left (fun env' (name, binding_expr) ->
        let thunk = make_thunk_ca binding_expr env  (* thunks capture current env, not extended env *)
        in
        extend_env env' name thunk
      ) env bindings in
      eval body env'

  | EFn (params, body) ->
      make_closure ~name:None params body (ref env)

  | EApply (fn_expr, arg_exprs) ->
      let fn_val = force (eval fn_expr env) in
      (* Create thunks for each argument *)
      let arg_thunks = List.map (fun arg_expr -> make_thunk_ca arg_expr env) arg_exprs in
      apply fn_val arg_thunks env

  | EQuote e ->
      quote_to_value e

  | EForce e ->
      force (eval e env)

  | EDelay e ->
      (* delay just returns a thunk; don't evaluate *)
      make_thunk_ca e env

  | EDo exprs ->
      (* Evaluate each in sequence, threading a mutable env so that
         imports, loads, and module loads affect subsequent expressions. *)
      let env_ref = ref env in
      let rec go = function
        | [] -> VNil
        | [last] ->
            let result = force (eval last !env_ref) in
            (match result with
             | VEnvMap bindings ->
                 env_ref := List.fold_left (fun e (n, v) ->
                   extend_env e n v) !env_ref bindings;
                 result
             | _ -> result)
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
            (* Evaluate in a fresh env with only builtins *)
            let mod_ref = ref (Primitives.initial_env ()) in
            ignore (eval_expressions exprs mod_ref);
            (* Export all bindings that aren't builtins *)
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
            (* Merge into the do-env so subsequent expressions see the exports *)
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
        | VNil -> []  (* no capabilities *)
        | _ -> extract_capabilities caps_val
      in
      let saved_caps = !current_capabilities in
      current_capabilities := caps @ saved_caps;
      let result = eval body env in
      current_capabilities := saved_caps;
      result

  | EPerform (name, arg_exprs) ->
      let args = List.map (fun e -> make_thunk_ca e env) arg_exprs in
      let forced_args = List.map force args in
      perform_effect name forced_args

  | EWithHandler (handlers, body) ->
      let saved_handlers = !handler_stack in
      (* Install handlers — each handler is a closure *)
      let new_handlers = List.map (fun (name, handler_expr) ->
        let handler_val = force (eval handler_expr env) in
        (name, fun args ->
          apply handler_val args env)
      ) handlers in
      handler_stack := new_handlers @ saved_handlers;
      let result = eval body env in
      handler_stack := saved_handlers;
      result

  | EDef (name, params, body) ->
      let closure = make_closure ~name:(Some name) params body (ref env) in
      closure

  | EDefFexpr (name, params, body) ->
      let fexpr = make_fexpr ~name:(Some name) params body (ref env) in
      fexpr

  | ELetStar (bindings, body) ->
      (* let* is desugared by the reader, but we handle it directly too *)
      let rec nest env' = function
        | [] -> eval body env'
        | (name, expr) :: rest ->
            let thunk = make_thunk_ca expr env' in
            let env'' = extend_env env' name thunk in
            nest env'' rest
      in
      nest env bindings

  | EModule body_exprs ->
      (* A module evaluates in a fresh env with only builtins, so its identity
         is stable regardless of where it's defined. Only exports its own bindings. *)
      let base_env = Primitives.initial_env () in
      let mod_env = ref base_env in
      let final_env = List.fold_left (fun (env_acc : env) e ->
        match e with
        | EDef (def_name, params, body) ->
            let closure = make_closure ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name closure
        | EDefFexpr (def_name, params, body) ->
            let fexpr = make_fexpr ~name:(Some def_name) params body (ref env_acc) in
            extend_env env_acc def_name fexpr
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
      (* Export only bindings added by the module (not builtins) *)
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
      VEnvMap new_bindings

  | EImport mod_expr ->
      (* Import at evaluation site: returns a VEnvMap to be merged by the
         caller (do-body, REPL, or file runner). *)
      let mod_val = force (eval mod_expr env) in
      (match mod_val with
       | VEnvMap _ -> mod_val  (* caller handles merging *)
       | _ -> failwith "import expects a module value")

  | ELoad path ->
      (* Load a file and evaluate it in the current env. *)
      let ch = open_in path in
      let source = really_input_string ch (in_channel_length ch) in
      close_in ch;
      let exprs = Reader.read_string source in
      let env_ref = ref env in
      eval_expressions exprs env_ref

  | ELoadModule path ->
      (* Load a file as a module: evaluate in a clean env (builtins only),
         export all non-builtin bindings as VEnvMap. *)
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
      VEnvMap (collect_new (!mod_ref).bindings base_bindings [])

(* ---- Function Application ---- *)

and apply (fn : value) (args : value list) (env : env) : value =
  match fn with
  | VClosure { fn_name = _; params; body; env = closure_env } ->
      if List.length params <> List.length args then
        failwith (Printf.sprintf "arity mismatch: expected %d args, got %d"
                    (List.length params) (List.length args));
      let env' = List.fold_left2 (fun e param arg ->
        extend_env e param arg  (* arg is already a thunk *)
      ) !closure_env params args in
      eval body env'

  | VFexpr { fexpr_name = _; fexpr_params; fexpr_body; fexpr_env } ->
      (* Fexpr receives unevaluated arg thunks captured from the CALLING environment.
         The fexpr decides which to force and when. *)
      if List.length fexpr_params <> List.length args then
        failwith (Printf.sprintf "fexpr arity mismatch: expected %d args, got %d"
                    (List.length fexpr_params) (List.length args));
      (* Bind parameters to the argument thunks (unevaluated).
         The thunks were created in the calling env by EApply, so forcing them
         evaluates in the caller's context. *)
      let env' = List.fold_left2 (fun e param arg ->
        extend_env e param arg
      ) !fexpr_env fexpr_params args in
      (* Expose the calling environment so the fexpr can introspect it *)
      let calling_env_val = VVector (Array.of_list (
        List.map (fun (n, v) -> VPair (VString n, v)) env.bindings)) in
      let env' = extend_env env' "calling-env" calling_env_val in
      eval fexpr_body env'

  | VBuiltin (name, f) ->
      (* Pass args as-is — each builtin decides which to force *)
      let forced_args = List.map (fun v ->
        match v with VThunk _ -> v | _ -> v  (* keep thunks! *)
      ) args in
      (try f forced_args
       with Failure msg ->
         failwith (Printf.sprintf "builtin '%s' failed: %s" name msg))

  | VMacro { params; body; env = macro_env } ->
      (* Macros receive un-evaluated expressions *)
      failwith "macros not yet supported"

  | _ ->
      failwith (Printf.sprintf "not a function: %s" (string_of_value fn))

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
           if not (has_fs_read (Filename.dirname path)) then
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
           if not (has_fs_write (Filename.dirname path)) then
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

(* Convert a quoted expression to a value (for quote) *)
and quote_to_value (e : expr) : value =
  match e with
  | ELiteral v -> v
  | ESymbol s -> VSymbol s
  | EIf _ -> failwith "cannot quote if"  (* shouldn't happen *)
  | ELet _ -> failwith "cannot quote let"
  | EFn (params, body) ->
      (* Quoted fn becomes a list: (fn (params...) body) *)
      VPair (VSymbol "fn",
        VPair (VVector (Array.of_list (List.map (fun p -> VSymbol p) params)),
          VPair (quote_to_value body, VNil)))
  | EApply (fn, args) ->
      let qfn = quote_to_value fn in
      let qargs = List.map quote_to_value args in
      let args_list = List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil in
      VPair (qfn, args_list)
  | EQuote e -> VPair (VSymbol "quote", VPair (quote_to_value e, VNil))
  | EForce e -> VPair (VSymbol "force", VPair (quote_to_value e, VNil))
  | EDelay e -> VPair (VSymbol "delay", VPair (quote_to_value e, VNil))
  | EDo exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "do", List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EDef (name, params, body) ->
      VPair (VSymbol "def",
        VPair (VSymbol name,
          VPair (list_to_list (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil),
            VPair (quote_to_value body, VNil))))
  | EDefFexpr (name, params, body) ->
      VPair (VSymbol "def-fexpr",
        VPair (VSymbol name,
          VPair (list_to_list (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil),
            VPair (quote_to_value body, VNil))))
  | ELetStar (bindings, body) ->
      VPair (VSymbol "let*",
        VPair (list_to_list (List.fold_right (fun (n, e) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)) bindings VNil),
          VPair (quote_to_value body, VNil)))
  | EEffect (caps, body) ->
      VPair (VSymbol "effect", VPair (quote_to_value caps, VPair (quote_to_value body, VNil)))
  | EPerform (name, args) ->
      let qargs = List.map quote_to_value args in
      VPair (VSymbol "perform",
        VPair (VSymbol name, list_to_list (List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil)))
  | EWithHandler (handlers, body) ->
      VPair (VSymbol "with-handler",
        VPair (list_to_list (List.fold_right (fun (n, h) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value h, VNil)), acc)) handlers VNil),
          VPair (quote_to_value body, VNil)))
  | EModule exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "module",
        List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EImport mod_expr ->
      VPair (VSymbol "import", VPair (quote_to_value mod_expr, VNil))
  | ELoad path ->
      VPair (VSymbol "load", VPair (VString path, VNil))
  | ELoadModule path ->
      VPair (VSymbol "load-module", VPair (VString path, VNil))

and list_to_list (v : value) : value = v  (* identity — already a list from fold_right *)

(* Evaluate expressions sequentially with mutable env — used by ELoad, ELoadModule, and REPL *)
and eval_expressions (exprs : expr list) (env : env ref) : value =
  let rec go = function
    | [] -> VNil
    | [last] ->
        (match last with
         | EDef (name, params, body) ->
             let closure = make_closure ~name:(Some name) params body env in
             env := extend_env !env name closure;
             closure
         | EDefFexpr (name, params, body) ->
             let fexpr = make_fexpr ~name:(Some name) params body env in
             env := extend_env !env name fexpr;
             fexpr
         | EImport mod_expr ->
             let mod_val = force (eval mod_expr !env) in
             (match mod_val with
              | VEnvMap bindings ->
                  env := List.fold_left (fun e (n, v) ->
                    extend_env e n v) !env bindings;
                  mod_val
              | _ -> failwith "import expects a module value")
         | ELoad path ->
             let ch = open_in path in
             let source = really_input_string ch (in_channel_length ch) in
             close_in ch;
             let exprs = Reader.read_string source in
             eval_expressions exprs env
         | _ ->
             let result = force (eval last !env) in
             (match result with
              | VEnvMap bindings ->
                  env := List.fold_left (fun e (n, v) ->
                    extend_env e n v) !env bindings;
                  result
              | _ -> result))
    | (EDef (name, params, body)) :: rest ->
        let closure = make_closure ~name:(Some name) params body env in
        env := extend_env !env name closure;
        go rest
    | (EDefFexpr (name, params, body)) :: rest ->
        let fexpr = make_fexpr ~name:(Some name) params body env in
        env := extend_env !env name fexpr;
        go rest
    | (EImport mod_expr) :: rest ->
        let mod_val = force (eval mod_expr !env) in
        (match mod_val with
         | VEnvMap bindings ->
             env := List.fold_left (fun e (n, v) ->
               extend_env e n v) !env bindings;
             go rest
         | _ -> failwith "import expects a module value")
    | (ELoad path) :: rest ->
        let ch = open_in path in
        let source = really_input_string ch (in_channel_length ch) in
        close_in ch;
        let exprs = Reader.read_string source in
        ignore (eval_expressions exprs env);
        go rest
    | e :: rest ->
        let result = force (eval e !env) in
        (match result with
         | VEnvMap bindings ->
             env := List.fold_left (fun e (n, v) ->
               extend_env e n v) !env bindings;
             go rest
         | _ -> go rest)
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
  current_capabilities := [];
  Hashtbl.clear thunk_store;
  Primitives.set_force force
