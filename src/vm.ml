(* pp bytecode VM — stack-based virtual machine executing bytecode *)

open Types
open Runtime

(* ---- VM State ---- *)

let operand_stack : value array ref = ref (Array.make 1024 VNil)
let sp = ref 0

(* handler_stack, current_capabilities, config_stack, thunk_store are in Runtime. *)
(* Save-stack so PUSH_HANDLER can restore the EXACT prior scope on
   POP_HANDLER regardless of how many handlers were pushed (D9: PUSH_HANDLER
   pushed n but one POP_HANDLER popped 1). Mirrors the tree-walker's
   saved/restore pattern. (with-caps' WITH_CAPS opcode below needs no
   analogous save-stack: it restores current_capabilities via an ordinary
   OCaml local + try/with around its nested run_isolated call, which is also
   what makes it exception-safe — see WITH_CAPS.) *)
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

(* Effect dispatch and type checking are shared with the tree-walker:
   Evaluator.perform_effect / check_type. One implementation, so the
   backends cannot drift. *)

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
                (* Trace replay for persistent node thunks: transitive
                   dependency capture, shared with the tree-walker. *)
                Evaluator.replay_node_reads t vm_node_key;
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
                      run_isolated bc' offset captured_frames
                  | None ->
                      failwith "VM: tree-walker thunk encountered in VM force"
                in
                (match t.type_ann with
                 | Some ty -> Evaluator.check_type result_val ty t.thunk_loc
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
             th.node_fv <- fv_descs;
             (* Node capture (Q11): the ambient at THIS creation, unconditionally
                — never left at the [] default (see Types.thunk.node_caps). *)
             th.node_caps <- !current_capabilities
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
             push (run_isolated c.vm_bc c.vm_offset callee_frames);
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

    | WITH_CAPS body_start ->
        let cap_val = pop () in
        let requested =
          match cap_val with
          | VCapability c -> c
          | _ -> failwith "with-caps expects a capability value"
        in
        if not (Capabilities.cap_subseteq requested !current_capabilities) then
          raise (Capability_error Capabilities.err_with_caps_widen);
        let saved = !current_capabilities in
        current_capabilities := [requested];
        (* Nested run_isolated call (not a flat opcode pair): the try/with
           here restores current_capabilities on EVERY exit — normal return
           AND a raised exception — which the flat ENTER/EXIT-opcode shape
           used by PUSH_HANDLER/PUSH_CONFIG cannot do (an OCaml exception
           thrown mid-body there unwinds straight past the EXIT opcode,
           since nothing in this VM's dispatch loop catches it). LAW 27. *)
        let result =
          try run_isolated !bc_ref body_start !local_frames
          with e -> current_capabilities := saved; raise e
        in
        current_capabilities := saved;
        push result;
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
        let r = Evaluator.perform_effect name args in
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
                run_isolated c.vm_bc c.vm_offset frames'
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
           fail identically outside the source roots. `~source:path`: the
           loaded file's OWN path, so its forms are located against it, not
           the reader's "<?>" default. *)
        let contents = Runtime.loader_read path in
        (* M3 defmacro: shared expansion hook, before compile_program ever
           sees these forms — Macro.ml is compiled after Vm.ml's
           dependencies (evaluator), so this is a direct call, not the
           Primitives-ref indirection evaluator.ml needs. *)
        let exprs = Macro.expand_toplevel_list
                      (Reader_braces.read_dispatch ~source:path ~path contents) in
        (* Compile and run ONE top-level form at a time (mirroring
           repl.ml's execute_file_bytecode for the outer file), each wrapped
           in ITS OWN location (LAW 29/D12): an error escaping a form here
           is decorated with the LOADED file's file:line before it can
           unwind past this LOAD_FILE, so it never surfaces as the loading
           `(load ...)` form's line. `run_isolated` (not run_program_expr)
           keeps `!local_frames` — a `load` can appear inside a function or
           block, and its forms only ever resolve names as VM globals
           (compiled with a fresh top-level cenv), so the ambient frame is
           passed through unused rather than replaced. *)
        let result = List.fold_left (fun _ e ->
          Runtime.with_form_location e (fun () ->
            let bc = Compiler.compile_program [e] in
            run_isolated bc 0 !local_frames)
        ) VNil exprs in
        push result;
        incr pc;
        loop ()

    | LOAD_MODULE_FILE i ->
        let path =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith "VM: LOAD_MODULE_FILE constant is not a string"
        in
        push (eval_module_from path !local_frames);
        incr pc;
        loop ()

    | ISLAND (uri_i, pin_i) ->
        (* D2: resolve the inline pin to the verified cached tree, then
           module-evaluate its entry.pp — mirrors the tree-walker's EIsland. *)
        let const_string i what =
          match (!bc_ref).consts.(i) with
          | VString s -> s
          | _ -> failwith ("VM: ISLAND " ^ what ^ " constant is not a string")
        in
        let uri = const_string uri_i "uri" in
        let pin = Option.map (fun i -> const_string i "pin") pin_i in
        let tree = Island.resolve ~uri ~pin in
        push (eval_module_from (Island.entry_file tree) !local_frames);
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

(* Evaluate a module file: run it against fresh globals and package the
   bindings it added as a VEnvMap. Shared by LOAD_MODULE_FILE and ISLAND.
   D20: does NOT merge into caller globals — the tree-walker's ELoadModule
   only returns the module value; statement-position merging is an explicit
   compiler-emitted IMPORT. *)
and eval_module_from (path : string) (frames : frame list) : value =
  let source =
    try Runtime.loader_read path
    with Sys_error msg -> failwith ("VM: cannot load module file: " ^ msg)
  in
  (* M7 S1: dispatch on [path]'s extension; label stays the "<?>" default. *)
  let exprs = Macro.expand_toplevel_list (Reader_braces.read_dispatch ~path source) in
  let prog = Compiler.compile_program exprs in
  let saved_globals = Hashtbl.copy globals in
  Hashtbl.clear globals;
  let initial = Primitives.initial_env () in
  List.iter (fun (n, v) -> Hashtbl.add globals n v) initial.bindings;
  ignore (run_isolated prog 0 frames);
  (* Collect bindings that are NOT part of the initial env. *)
  let new_bindings = ref [] in
  Hashtbl.iter (fun n v ->
    if not (List.exists (fun (pn, _) -> pn = n) initial.bindings) then
      new_bindings := (n, v) :: !new_bindings
  ) globals;
  Hashtbl.clear globals;
  Hashtbl.iter (fun n v -> Hashtbl.add globals n v) saved_globals;
  VEnvMap (List.rev !new_bindings)

(* Run a bytecode region on a fresh, isolated operand stack, restoring the
   caller's stack on return. Every nested execution (calls, thunk forcing,
   handlers) goes through here so an inner run can never corrupt the
   caller's operands. *)
and run_isolated (bc : bytecode) (offset : int) (frames : frame list) : value =
  let saved_sp = !sp in
  let saved_stack = !operand_stack in
  sp := 0;
  operand_stack := Array.make 1024 VNil;
  let restore () = sp := saved_sp; operand_stack := saved_stack in
  match run bc offset frames with
  | r -> restore (); r
  | exception e -> restore (); raise e

(* ---- VM-side force for builtins ---- *)

and vm_force (v : value) : value =
  match v with
  | VThunk t ->
      begin match t.thunk_status with
      | Evaluated result ->
          (* Trace replay for persistent node thunks (same mechanism as
             evaluator.ml force and Store.hit hit-replay). *)
          Evaluator.replay_node_reads t vm_node_key;
          vm_force result
      | Evaluating -> failwith "VM force: infinite recursion"
      | Unevaluated ->
          if t.thunk_persist then
            vm_force (force_node_thunk t)
          else
          begin match t.vm_code with
          | Some (bc', offset, frames') ->
              t.thunk_status <- Evaluating;
              let r = run_isolated bc' offset frames' in
              (match t.type_ann with
               | Some ty -> Evaluator.check_type r ty t.thunk_loc
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
   backend, so those key separately but each remains sound.

   M3 free-var ban (LAW 20 node-boundary, import side; extended M4/LAW 39 to
   VSealed): if a free variable's forced value contains a VCapability or
   VSealed (Hasher.contains_authority — never forces an already-Unevaluated
   thunk, so this can't force the same value twice or invalidate the "each is
   forced" note above; it just inspects whatever [vm_force] already
   produced), the key can never be computed — raise Capability_error instead,
   naming the variable. If forcing itself raises Capability_error (e.g. the
   free var's value is itself a node whose force hit this same ban, or a
   use-time gate), propagate that as-is rather than falling back to hashing
   the unforced thunk. *)
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
      let hv =
        match vm_force v with
        | fv ->
            if Hasher.contains_authority fv then
              raise (Capability_error
                (Printf.sprintf
                   "node: free variable '%s' may not be or contain a %s" name
                   (if Hasher.contains_sealed fv then "sealed value" else "capability")));
            hash_value fv
        | exception e ->
            (match e with
             | Capability_error _ -> raise e
             | _ -> hash_value v)
      in
      hash_concat ["fv"; name; hv])
      t.node_fv
  in
  (* Ambient config/handlers are deliberately NOT in the key: what a node
     observed of them is recorded as config:/handler: trace cells and governs
     validity, not identity (LAW 33/26) — same as the tree-walker. *)
  hash_concat (["node-key"; hash_expr t.thunk_expr] @ fv_parts)

(* Force a persistent VM node through the store: hit verification, failure
   memoization, trace recording, and the --check audit all live in
   Evaluator.force_node — one rebuilder for both backends. Shared by the FORCE
   opcode and vm_force so a node caches identically however it is demanded.
   Assumes t is persistent and Unevaluated. *)
and force_node_thunk (t : thunk) : value =
  let run () =
    match t.vm_code with
    | Some (bc', offset, cf) -> run_isolated bc' offset cf
    | None -> failwith "VM: node thunk without vm_code"
  in
  Evaluator.force_node ~key:(vm_node_key t) ~run t

(* ---- Public: run a single expression bytecode without re-initialising VM state ---- *)
let run_program_expr (prog : bytecode) : value =
  let root_frame = make_frame 0 in
  let r = run_isolated prog 0 [root_frame] in
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
  handler_save_stack := [];
  if not !Runtime.keep_thunks then Hashtbl.clear thunk_store;
  Primitives.set_force vm_force;
  (* Config-cell observations (LAW 33) hash the forced value; under the VM the
     forcing is vm_force (Evaluator.init is not run on this path). *)
  Runtime.force_hook := vm_force;
  Primitives.vm_run_thunk_ref := run_isolated;
  (* Phase 3: let Primitives' scheduler-aware force-deep compute VM node keys
     without a dependency cycle (Primitives is compiled before Vm). *)
  Primitives.vm_node_key_ref := vm_node_key;
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
