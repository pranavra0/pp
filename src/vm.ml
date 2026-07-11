(* pp bytecode VM — stack-based virtual machine executing bytecode *)

open Types
open Runtime

(* ---- VM State ---- *)

let operand_stack : value array ref = ref (Array.make 1024 VNil)
let sp = ref 0

(* handler_stack, current_capabilities, config_stack, thunk_store are in Runtime. *)
(* Save-stacks so ENTER_EFFECT/PUSH_HANDLER can restore the EXACT prior scope
   on EXIT_EFFECT/POP_HANDLER regardless of how many caps/handlers were pushed
   (D9: ENTER pushed N but EXIT popped 1; PUSH_HANDLER pushed n but one
   POP_HANDLER popped 1). Mirrors the tree-walker's saved/restore pattern. *)
let caps_save_stack : capability list list ref = ref []
let handler_save_stack : (string * (value list -> value) * string) list list ref = ref []
let globals : (string, value) Hashtbl.t = Hashtbl.create 128

(* ---- Stack helpers ---- *)

let push v =
  let i = !sp in
  if i >= Array.length !operand_stack then begin
    let ncap = Array.length !operand_stack * 2 in
    let a = Array.make ncap VNil in
    Array.blit !operand_stack 0 a 0 i;
    operand_stack := a
  end;
  !operand_stack.(i) <- v;
  sp := i + 1

let pop () =
  let i = !sp - 1 in
  if i < 0 then failwith "VM: stack underflow";
  let v = !operand_stack.(i) in
  !operand_stack.(i) <- VNil;
  sp := i;
  v

let pop_n n =
  let result = Array.make n VNil in
  for i = n - 1 downto 0 do
    result.(i) <- pop ()
  done;
  Array.to_list result

let peek n =
  !operand_stack.(!sp - 1 - n)

(* ---- Effect helpers (copied from evaluator.ml) ---- *)

let rec has_fs_read (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_read cap path) !current_capabilities

let has_fs_write (path : string) : bool =
  List.exists (fun cap -> Capabilities.check_fs_write cap path) !current_capabilities

let rec extract_capabilities (v : value) : capability list =
  match v with
  | VCapability c -> [c]
  | VVector vs -> Array.to_list (Array.map (fun v' ->
      match Primitives.force_val v' with VCapability c -> c | _ -> failwith "capability vector must contain capabilities"
    ) vs)
  | VPair _ ->
      let rec collect acc = function
        | VNil -> List.rev acc
        | VPair (v', rest) ->
            (match Primitives.force_val v' with
             | VCapability c -> collect (c :: acc) rest
             | _ -> failwith "not a capability")
        | _ -> failwith "capability list must be a proper list"
      in
      collect [] v
  | _ -> failwith ("expected capability, got: " ^ string_of_value v)

let perform_builtin_effect (name : string) (args : value list) : value =
  match name with
  | "read-file" ->
      (match args with
       | [VString path] ->
           (* Node-local sandbox scratch reads: capability-free, unrecorded
              (LAW 18) — same rule as the tree-walker. *)
           (match Process.sandbox_read path with
            | Some content -> VString content
            | None ->
              if not (has_fs_read path) then
                raise (Types.Capability_error ("read-file: capability error: no read access for " ^ path));
              (* Cell observation: recorded + CAS-pinned in node context (Q11). *)
              (try VString (Store.read_file_cell path)
               with Sys_error msg -> failwith ("read-file: " ^ msg)))
       | _ -> failwith "read-file expects a string path")
  | "write-file" ->
      (match args with
       | [VString path; VString content] ->
           (* LAW 18 node/scripting split — shared with the tree-walker. *)
           Process.write_file_effect ~has_cap:has_fs_write path content
       | _ -> failwith "write-file expects path and content strings")
  | "run" ->
      (* D13: process execution — capability-gated, trace-recorded, sandboxed. *)
      Process.run_effect args
  | "run-dep" ->
      (* Q2 refinement: run + depfile → precise cells, no coarse tree cells. *)
      Process.run_dep_effect args
  | "log" ->
      (match args with
       | [VString level; VString msg] ->
           Printf.eprintf "[%s] %s\n%!" level msg; VNil
       | [VString msg] ->
           Printf.eprintf "[info] %s\n%!" msg; VNil
       | _ -> failwith "log expects a message string")
  | _ ->
      failwith ("unhandled effect: " ^ name)

let perform_effect (name : string) (args : value list) : value =
  (* LAW 26: which handler intercepts (or that none does) is an observation;
     inside a node it is recorded as a `handler:<effect>` trace cell — same as
     the tree-walker's perform_effect. *)
  Runtime.record_handler_observation name;
  (* Check handler stack *)
  let rec find_handler = function
    | [] -> perform_builtin_effect name args
    | (hname, h, _) :: rest ->
        if hname = name then h args
        else find_handler rest
  in
  find_handler !handler_stack

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

(* ---- Force via VM (for evaluator.force to dispatch into) ---- *)

(* Saved evaluator force — vm_force falls back to this for tree-walker thunks.
   Declared before `run` so the mutually-recursive `vm_force` (below) can use it. *)
let saved_eval_force : (value -> value) ref = ref (fun v -> v)

(** Run a bytecode program starting at a given pc with given frames.
    Returns the result value (top of operand stack at HALT/RETURN). *)
let rec run (bc : bytecode) (start_pc : int) (frames : frame list) : value =
  let bc_ref = ref bc in
  let pc = ref start_pc in
  let local_frames = ref frames in
  let result = ref VNil in

  let rec loop () =
    if !pc < 0 || !pc >= Array.length !bc_ref.code then
      failwith (Printf.sprintf "VM: pc out of bounds (%d), bc len %d" !pc (Array.length !bc_ref.code));

    match !bc_ref.code.(!pc) with
    | PUSH i ->
        push (!bc_ref).consts.(i);
        incr pc;
        loop ()

    | LOAD_LOCAL (depth, slot) ->
        let f = List.nth !local_frames depth in
        push (frame_get f slot);
        incr pc;
        loop ()

    | STORE_LOCAL slot ->
        let v = pop () in
        (match !local_frames with
         | [] -> failwith "VM: STORE_LOCAL with no frames"
         | f :: _ -> frame_set f slot v);
        incr pc;
        loop ()

    | LOAD_GLOBAL i ->
        let name =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: LOAD_GLOBAL constant is not a string"
        in
        (match Hashtbl.find_opt globals name with
         | Some v -> push v
         | None ->
             (match Primitives.lookup name with
              | Some v -> push v
              (* Same text as the tree-walker's ESymbol miss — unbound-name
                 errors must not reveal which backend ran. *)
              | None -> failwith ("unbound symbol: " ^ name)));
        incr pc;
        loop ()

    | STORE_GLOBAL i ->
        let v = pop () in
        let name =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: STORE_GLOBAL constant is not a string"
        in
        Hashtbl.replace globals name v;
        (* Keep the tree-walker's current-env view in sync so that
           eval-pp sees VM globals as its calling environment. *)
        Primitives.current_env_ref := Types.extend_env !Primitives.current_env_ref name v;
        incr pc;
        loop ()

    | POP ->
        ignore (pop ());
        incr pc;
        loop ()

    | DUP ->
        let v = pop () in
        push v;
        push v;
        incr pc;
        loop ()

    | JUMP offset ->
        pc := !pc + offset;
        loop ()

    | JUMP_IF_FALSE offset ->
        let v = pop () in
        let is_false = match v with VNil -> true | VBool false -> true | _ -> false in
        if is_false then pc := !pc + offset else incr pc;
        loop ()

    | FORCE ->
        let v = pop () in
        begin match v with
        | VThunk t ->
            begin match t.thunk_status with
            | Evaluated result ->
                (* Trace replay for persistent node thunks: when a caller forces
                   an already-Evaluated node, replay its stored trace reads into
                   active trace frames for transitive dependency capture. *)
                (if t.thunk_persist && !Runtime.trace_stack <> [] then
                   let nk = vm_node_key t in
                   let open Store in
                   let traces = load_traces ~key:nk in
                   List.iter (fun tr ->
                     List.iter (fun (c, h) -> Runtime.record_read c h) tr.tr_reads
                   ) traces);
                push result;
                incr pc;
                loop ()
            | Evaluating ->
                failwith "VM: infinite recursion detected (forcing a thunk already being evaluated)"
            | Unevaluated when t.thunk_persist ->
                (* Persistent node: route through the store (LAW 16/17/20/21/23/28),
                   shared with vm_force. *)
                let result_val = force_node_thunk t in
                push result_val;
                incr pc;
                loop ()
            | Unevaluated ->
                t.thunk_status <- Evaluating;
                let result_val =
                  match t.vm_code with
                  | Some (bc', offset, captured_frames) ->
                      let saved_sp = !sp in
                      let saved_stack = !operand_stack in
                      sp := 0;
                      operand_stack := Array.make 1024 VNil;
                      let r = run bc' offset captured_frames in
                      sp := saved_sp;
                      operand_stack := saved_stack;
                      r
                  | None ->
                      failwith "VM: tree-walker thunk encountered in VM force"
                in
                (match t.type_ann with
                 | Some ty -> check_type result_val ty t.thunk_loc
                 | None -> ());
                t.thunk_status <- Evaluated result_val;
                push result_val;
                incr pc;
                loop ()
            end
        | _ ->
            push v;
            incr pc;
            loop ()
        end


    | MAKE_THUNK (offset, type_ann, thunk_loc) ->
        let captured = !local_frames in
        let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
        let t = make_thunk ~vm_code:(Some (!bc_ref, offset, captured))
                   ~type_ann ~thunk_loc ~config_hash:cfg_hash
                   (ELiteral VNil)
                   empty_env
        in
        (match t with
         | VThunk th ->
             th.thunk_hash <- Some (hash_concat ["vm-thunk"; string_of_int offset; cfg_hash])
         | _ -> ());
        push t;
        incr pc;
        loop ()
    | MAKE_NODE (offset, body_ast, fv_descs, type_ann, thunk_loc) ->
        (* Persistent node thunk: carries the captured frames (for execution) plus
           the body AST and free-var descriptors (for the LAW 20 node key). *)
        let captured = !local_frames in
        let cfg_hash = hash_concat ("cfg" :: List.map hash_value !config_stack) in
        let t = make_thunk ~vm_code:(Some (!bc_ref, offset, captured))
                   ~type_ann ~thunk_loc ~config_hash:cfg_hash
                   body_ast
                   empty_env
        in
        (match t with
         | VThunk th ->
             th.thunk_persist <- true;
             th.node_fv <- fv_descs
         | _ -> ());
        push t;
        incr pc;
        loop ()
    | MAKE_CLOSURE (offset, nparams) ->
        let captured = !local_frames in
        let params =
          match Hashtbl.find_opt (!bc_ref).param_names_of offset with
          | Some names -> names
          | None -> []
        in
        let fn_name = Hashtbl.find_opt (!bc_ref).closure_names_of offset in
        push (VClosure {
          fn_name;
          params;
          body = ELiteral VNil;
          env = ref empty_env;
          vm_bc = !bc_ref;
          vm_offset = offset;
          vm_frames = captured;
        });
        incr pc;
        loop ()


    | CALL n ->
        let args = pop_n n in
        let fn_val = pop () in
        (match fn_val with
         | VClosure c when c.vm_bc == Types.dummy_bytecode ->
             (* Tree-walker closure invoked from bytecode — fall back to
                the evaluator's apply. *)
             let r = !Primitives.apply_ref fn_val args !Primitives.current_env_ref in
             push r;
             incr pc;
             loop ()
         | VClosure c ->
             let nparams = List.length c.params in
             if n <> nparams then begin
               let fname = match c.fn_name with Some nm -> nm | None -> "#<fn>" in
               failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d" fname nparams n)
             end;
             let new_frame = make_frame nparams in
             List.iteri (fun i arg ->
               frame_set new_frame i arg
             ) args;
             let callee_frames = new_frame :: c.vm_frames in
             let saved_sp = !sp in
             let saved_stack = !operand_stack in
             sp := 0;
             operand_stack := Array.make 1024 VNil;
             let r = run c.vm_bc c.vm_offset callee_frames in
             sp := saved_sp;
             operand_stack := saved_stack;
             push r;
             incr pc;
             loop ()
         | VBuiltin (name, f) ->
             let r = f args in
             push r;
             incr pc;
             loop ()
         | _ ->
             failwith (Printf.sprintf "VM: CALL on non-function: %s" (string_of_value fn_val)))

    | TAIL_CALL n ->
        let args = pop_n n in
        let fn_val = pop () in
        (match fn_val with
         | VClosure c when c.vm_bc == Types.dummy_bytecode ->
             result := !Primitives.apply_ref fn_val args !Primitives.current_env_ref
         | VClosure c ->
             let nparams = List.length c.params in
             if n <> nparams then begin
               let fname = match c.fn_name with Some nm -> nm | None -> "#<fn>" in
               failwith (Printf.sprintf "arity mismatch calling %s: expected %d args, got %d" fname nparams n)
             end;
             let new_frame = make_frame nparams in
             List.iteri (fun i arg ->
               frame_set new_frame i arg
             ) args;
             local_frames := new_frame :: c.vm_frames;
             bc_ref := c.vm_bc;
             pc := c.vm_offset;
             loop ()
         | VBuiltin (name, f) ->
             (* Tail-calling a builtin: evaluate and return result to caller *)
             let r = f args in
             result := r
         | _ ->
             failwith (Printf.sprintf "VM: TAIL_CALL on non-function: %s" (string_of_value fn_val)))

    | RETURN ->
        (* Pop result from current frame's execution and return to caller *)
        result := pop ();
        (* The caller (nested run) will pick up the result *)
        (* We just exit the loop *)

    | HALT ->
        result := (if !sp > 0 then pop () else VNil)

    | BUILTIN i ->
        let name =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: BUILTIN constant is not a string"
        in
        (match Primitives.lookup name with
         | Some v -> push v
         | None -> failwith ("VM: unknown builtin: " ^ name));
        incr pc;
        loop ()

    | CONS ->
        let b = pop () in
        let a = pop () in
        push (VPair (a, b));
        incr pc;
        loop ()

    | ENTER_EFFECT ->
        let caps_val = pop () in
        let caps =
          match caps_val with
          | VNil -> []
          | _ -> extract_capabilities caps_val
        in
        caps_save_stack := !current_capabilities :: !caps_save_stack;
        current_capabilities := caps @ !current_capabilities;
        incr pc;
        loop ()

    | EXIT_EFFECT ->
        (* Restore the pre-ENTER scope exactly, not pop-one (D9). *)
        (match !caps_save_stack with
         | [] -> ()
         | saved :: rest ->
             current_capabilities := saved;
             caps_save_stack := rest);
        incr pc;
        loop ()

    | PERFORM (namei, nargs) ->
        (* Force args before dispatch, mirroring the tree-walker
           (evaluator.ml EPerform forces each arg before perform_effect). *)
        let args = List.map Primitives.force_val (pop_n nargs) in
        let name =
          match (!bc_ref).consts.(namei) with
          | VString s -> s
          | _ -> failwith "VM: PERFORM constant is not a string"
        in
        let r = perform_effect name args in
        push r;
        incr pc;
        loop ()

    | PUSH_HANDLER n ->
        (* n (name, closure) pairs already on stack; 
           pop them and push onto handler stack *)
        let pairs = ref [] in
        for _ = 1 to n do
          let handler_val = pop () in
          let name_val = pop () in
          let name =
            match name_val with
            | VString s -> s
            | _ -> failwith "VM: PUSH_HANDLER name is not a string"
          in
          pairs := (name, handler_val) :: !pairs
        done;
        let new_handlers = List.map (fun (n, hv) ->
          (n,
           (fun args ->
            (* Invoke the handler FUNCTION with the (already-forced) effect
               args and return its result, mirroring the tree-walker's
               [fun args -> apply handler_val args env] (evaluator.ml
               EWithHandler). [hv] is now the real handler function (the
               compiler no longer wraps it in a 0-param region). Save/restore
               the operand stack exactly like CALL (D20): [run] shares the
               module-global operand_stack/sp. *)
            match hv with
            | VClosure c when c.vm_bc == Types.dummy_bytecode ->
                !Primitives.apply_ref hv args !Primitives.current_env_ref
            | VClosure c ->
                let nparams = List.length c.params in
                if List.length args <> nparams then begin
                  let fname = match c.fn_name with Some nm -> nm | None -> "#<fn>" in
                  failwith (Printf.sprintf
                    "arity mismatch calling %s: expected %d args, got %d"
                    fname nparams (List.length args))
                end;
                let new_frame = make_frame nparams in
                List.iteri (fun i arg -> frame_set new_frame i arg) args;
                let frames' = new_frame :: c.vm_frames in
                let saved_sp = !sp in
                let saved_stack = !operand_stack in
                sp := 0;
                operand_stack := Array.make 1024 VNil;
                let r = run c.vm_bc c.vm_offset frames' in
                sp := saved_sp;
                operand_stack := saved_stack;
                r
            | VBuiltin (_, f) -> f args
            | _ -> failwith ("VM: handler is not a function: " ^ string_of_value hv)
           ),
           hash_value hv)   (* D17: handler identity in the key *)
        ) !pairs in
        handler_save_stack := !handler_stack :: !handler_save_stack;
        handler_stack := new_handlers @ !handler_stack;
        incr pc;
        loop ()

    | POP_HANDLER ->
        (* Restore the pre-PUSH handler stack exactly, not pop-one (D9). *)
        (match !handler_save_stack with
         | [] -> ()
         | saved :: rest ->
             handler_stack := saved;
             handler_save_stack := rest);
        incr pc;
        loop ()

    | MAKE_MODULE n ->
        let bindings = ref [] in
        for _ = 1 to n do
          let thunk_val = pop () in
          let name_val = pop () in
          let name =
            match name_val with
            | VString s -> s
            | _ -> failwith "VM: MAKE_MODULE name is not a string"
          in
          bindings := (name, thunk_val) :: !bindings
        done;
        push (VEnvMap (List.rev !bindings));
        incr pc;
        loop ()

    | IMPORT ->
        let mod_val = pop () in
        (match mod_val with
         | VEnvMap bindings ->
             let current_frame = match !local_frames with
               | f :: _ -> f
               | [] -> failwith "VM: IMPORT with no current frame"
             in
             List.iter (fun (name, v) ->
               let slot = current_frame.len in
               frame_set current_frame slot v;
               Hashtbl.replace globals name v
             ) bindings;
             (* Tree-walker's EImport returns the module value; push it so
                import works in expression position too. Statement-position
                emitters follow IMPORT with POP. *)
             push mod_val
         | _ -> failwith "VM: IMPORT expects a module value");
        incr pc;
        loop ()

    | LOAD_FILE i ->
        let path =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: LOAD_FILE constant is not a string"
        in
        (* Loader authority: bounded + runtime-cell recorded (Q6/D8c) —
           same helper as the tree-walker's ELoad/EIsland, so both backends
           fail identically outside the source roots. *)
        let source = Runtime.loader_read path in
        let exprs = Reader.read_string source in
        let prog = Compiler.compile_program exprs in
        let saved_sp = !sp in
        let saved_stack = !operand_stack in
        sp := 0;
        operand_stack := Array.make 1024 VNil;
        let result = run prog 0 !local_frames in
        sp := saved_sp;
        operand_stack := saved_stack;
        push result;
        incr pc;
        loop ()

    | LOAD_MODULE_FILE i ->
        let path =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: LOAD_MODULE_FILE constant is not a string"
        in
        let source =
          try Runtime.loader_read path
          with Sys_error msg -> failwith ("VM: cannot load module file: " ^ msg)
        in
        let exprs = Reader.read_string source in
        let prog = Compiler.compile_program exprs in
        let saved_globals = Hashtbl.copy globals in
        Hashtbl.clear globals;
        let initial = Primitives.initial_env () in
        List.iter (fun (n, v) -> Hashtbl.add globals n v) initial.bindings;
        let saved_sp = !sp in
        let saved_stack = !operand_stack in
        sp := 0;
        operand_stack := Array.make 1024 VNil;
        ignore (run prog 0 !local_frames);
        sp := saved_sp;
        operand_stack := saved_stack;
        (* Collect bindings that are NOT part of the initial env. *)
        let new_bindings = ref [] in
        Hashtbl.iter (fun n v ->
          if not (List.exists (fun (pn, _) -> pn = n) initial.bindings) then
            new_bindings := (n, v) :: !new_bindings
        ) globals;
        Hashtbl.clear globals;
        Hashtbl.iter (fun n v -> Hashtbl.add globals n v) saved_globals;
        (* D20: do NOT merge into caller globals here; the tree-walker's
           ELoadModule only returns the module value. Statement-position
           merging is done by an explicit IMPORT emitted by the compiler. *)
        push (VEnvMap (List.rev !new_bindings));
        incr pc;
        loop ()

    | NOP ->
        incr pc;
        loop ()

    | PUSH_CONFIG ->
        let cfg = pop () in
        (match cfg with
         | VMap _ -> config_stack := cfg :: !config_stack
         | _ -> failwith "VM: PUSH_CONFIG expects a map");
        incr pc;
        loop ()

    | POP_CONFIG ->
        (match !config_stack with
         | [] -> failwith "VM: POP_CONFIG with empty config stack"
         | _ :: rest -> config_stack := rest);
        incr pc;
        loop ()

    | READ_CONFIG ->
        let key_val = pop () in
        let key_name = match key_val with
          | VString s | VKeyword s | VSymbol s -> s
          | _ -> failwith "VM: READ_CONFIG key must be a string, keyword, or symbol"
        in
        (* LAW 33: a config read inside a node is a recorded observation —
           same cell and lookup rule as the tree-walker's EConfig. *)
        Runtime.record_config_read key_name;
        push (match Runtime.config_lookup key_name with
              | Some v -> v
              | None -> VNil);
        incr pc;
        loop ()
  in
  loop ();
  !result



(* ---- VM-side force for builtins ---- *)

and vm_force (v : value) : value =
  match v with
  | VThunk t ->
      begin match t.thunk_status with
      | Evaluated result ->
          (* Trace replay for persistent node thunks (same mechanism as
             evaluator.ml force and Store.hit hit-replay). *)
          (if t.thunk_persist && !Runtime.trace_stack <> [] then
             let nk = vm_node_key t in
             let open Store in
             let traces = load_traces ~key:nk in
             List.iter (fun tr ->
               List.iter (fun (c, h) -> Runtime.record_read c h) tr.tr_reads
             ) traces);
          vm_force result
      | Evaluating -> failwith "VM force: infinite recursion"
      | Unevaluated ->
          if t.thunk_persist then
            vm_force (force_node_thunk t)
          else
          begin match t.vm_code with
          | Some (bc', offset, frames') ->
              t.thunk_status <- Evaluating;
              let saved_sp = !sp in
              let saved_stack = !operand_stack in
              sp := 0;
              operand_stack := Array.make 1024 VNil;
              let r = run bc' offset frames' in
              sp := saved_sp;
              operand_stack := saved_stack;
              (match t.type_ann with
               | Some ty -> check_type r ty t.thunk_loc
               | None -> ());
              t.thunk_status <- Evaluated r;
              vm_force r
          | None ->
              !saved_eval_force v
          end
      end
  | _ -> v

(* LAW 20 node key for a VM node thunk. A VM thunk carries bytecode+frames rather
   than an AST+env, so the free variables are resolved from the descriptors the
   compiler emitted (MAKE_NODE): a Local (depth,slot) reads the captured frame,
   a Global (depth < 0) reads the globals table. Each is forced (call-by-value)
   and hashed. The key format is byte-identical to the tree-walker's
   `node_key_of`, so a node whose free vars are data (strings, ints, …) produces
   the SAME key in both backends and shares the store entry; closures hash per
   backend, so those key separately but each remains sound. *)
and vm_node_key (t : thunk) : string =
  let frames = match t.vm_code with Some (_, _, fr) -> fr | None -> [] in
  let fv_parts =
    List.map (fun (name, depth, slot) ->
      let v =
        if depth < 0 then
          (match Hashtbl.find_opt globals name with Some v -> v | None -> VNil)
        else
          (try frame_get (List.nth frames depth) slot with _ -> VNil)
      in
      let hv = (try hash_value (vm_force v) with _ -> hash_value v) in
      hash_concat ["fv"; name; hv])
      t.node_fv
  in
  (* Ambient config/handlers are deliberately NOT in the key: what a node
     observed of them is recorded as config:/handler: trace cells and governs
     validity, not identity (LAW 33/26) — same as the tree-walker. *)
  hash_concat (["node-key"; hash_expr t.thunk_expr] @ fv_parts)

(* Force a persistent VM node through the store: verify a hit (authority-gated),
   else run the body under a fresh trace frame and store the result (or a failing
   trace). Shared by the FORCE opcode and vm_force so a node caches identically
   however it is demanded. Assumes t is persistent and Unevaluated. *)
and force_node_thunk (t : thunk) : value =
  let nk = vm_node_key t in
  Stabilize.register_node_key ~key:nk ~thunk:t;
  match Store.hit ~key:nk ~authorized:Evaluator.cell_authorized with
  | Store.HitOk cached -> t.thunk_status <- Evaluated cached; cached
  | Store.HitFailed errval ->
      (match errval with VString m -> failwith m | _ -> failwith "node failed (cached)")
  | Store.Miss ->
      t.thunk_status <- Evaluating;
      let tframe = Runtime.push_trace_frame () in
      let result =
        try
          let r =
            match t.vm_code with
            | Some (bc', offset, cf) ->
                let saved_sp = !sp in
                let saved_stack = !operand_stack in
                sp := 0;
                operand_stack := Array.make 1024 VNil;
                let r = run bc' offset cf in
                sp := saved_sp;
                operand_stack := saved_stack;
                r
            | None -> failwith "VM: node thunk without vm_code"
          in
          Runtime.pop_trace_frame ();
          r
        with
        | Failure msg as e ->
            Runtime.pop_trace_frame ();
            let errval = VString msg in
            let err_hash = hash_value errval in
            (try Store.store_object ~key:err_hash ~value:errval with _ -> ());
            (try Store.store_trace ~key:nk ~outcome:Failed ~result_hash:err_hash
                   ~reads:(List.rev !tframe) with _ -> ());
            t.thunk_status <- Unevaluated;
            raise e
        | e ->
            Runtime.pop_trace_frame ();
            t.thunk_status <- Unevaluated;
            raise e
      in
      (match t.type_ann with
       | Some ty -> check_type result ty t.thunk_loc
       | None -> ());
      t.thunk_status <- Evaluated result;
      let result_hash = hash_value result in
      (try Store.store_object ~key:result_hash ~value:result with _ -> ());
      (try Store.store_trace ~key:nk ~outcome:Ok ~result_hash
             ~reads:(List.rev !tframe) with _ -> ());
      (* --check (LAW 38): re-run the body and compare result hashes — same
         audit as the tree-walker's evaluate_and_store. *)
      if !Store.check_mode then begin
        (match t.vm_code with
         | Some (bc', offset, cf) ->
             let frame2 = Runtime.push_trace_frame () in
             ignore frame2;
             let r2 =
               try
                 let saved_sp = !sp in
                 let saved_stack = !operand_stack in
                 sp := 0;
                 operand_stack := Array.make 1024 VNil;
                 let r = run bc' offset cf in
                 sp := saved_sp;
                 operand_stack := saved_stack;
                 r
               with e -> Runtime.pop_trace_frame (); raise e
             in
             Runtime.pop_trace_frame ();
             if hash_value r2 <> result_hash then begin
               incr Store.volatile_count;
               Printf.eprintf
                 "[check] volatile node %s: an identical run produced a different result hash\n%!"
                 (Store.short_key nk)
             end
         | None -> ())
      end;
      result

(* ---- Public: run a single expression bytecode without re-initialising VM state ---- *)
let run_program_expr (prog : bytecode) : value =
  let root_frame = make_frame 0 in
  let saved_sp = !sp in
  let saved_stack = !operand_stack in
  sp := 0;
  operand_stack := Array.make 1024 VNil;
  let r = run prog 0 [root_frame] in
  sp := saved_sp;
  operand_stack := saved_stack;
  (* Match the tree-walker's eval_expressions: a top-level statement whose
     value is a module (VEnvMap) has its bindings merged into the top-level
     environment (covers bare `(module ...)` and `(load-module ...)`). *)
  (match r with
   | VEnvMap bindings ->
       List.iter (fun (name, v) -> Hashtbl.replace globals name v) bindings
   | _ -> ());
  r

(* ---- VM init and registration ---- *)

let rec init () =
  Evaluator.init ();
  saved_eval_force := !Primitives.force_ref;
  Hashtbl.clear globals;
  let initial = Primitives.initial_env () in
  List.iter (fun (name, v) ->
    Hashtbl.add globals name v
  ) initial.bindings;
  (* Build an env from all globals so tree-walker callbacks (eval-pp)
     can see the same top-level bindings as the VM. *)
  let global_bindings = Hashtbl.fold (fun name v acc -> (name, v) :: acc) globals [] in
  Primitives.current_env_ref := Types.env_of_bindings global_bindings;
  handler_stack := [];
  config_stack := [];
  caps_save_stack := [];
  handler_save_stack := [];
  if not !Runtime.keep_thunks then Hashtbl.clear thunk_store;
  Primitives.set_force vm_force;
  (* Config-cell observations (LAW 33) hash the forced value; under the VM the
     forcing is vm_force (Evaluator.init is not run on this path). *)
  Runtime.force_hook := vm_force;
  Primitives.vm_run_thunk_ref := (fun bc offset frames ->
    (* Run a VM region with an isolated operand stack. *)
    let saved_sp = !sp in
    let saved_stack = !operand_stack in
    sp := 0;
    operand_stack := Array.make 1024 VNil;
    let r = run bc offset frames in
    sp := saved_sp;
    operand_stack := saved_stack;
    r
  );
  Primitives.vm_run_bytecode_ref := (fun bc ->
    run_program bc
  );
  (* Wire the VM global-definition hook so that eval-pp definitions
     become visible to subsequent bytecode. *)
  Primitives.vm_define_ref := (fun name v ->
    Hashtbl.replace globals name v
  )

(* ---- Public: compile and run entry point (used by main.ml --bytecode) ---- *)
and run_program (prog : bytecode) : value =
  init ();
  run_program_expr prog
