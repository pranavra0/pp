(* pp bytecode compiler — compiles expr AST to bytecode *)

open Types

(* ---- Constant pool ---- *)

let intern (st : comp_state) (v : value) : int =
  let h = hash_value v in
  match Hashtbl.find_opt st.const_ht h with
  | Some idx -> idx
  | None ->
      let idx = List.length st.consts in
      st.consts <- st.consts @ [v];
      Hashtbl.add st.const_ht h idx;
      idx

let intern_name (st : comp_state) (name : string) : int =
  intern st (VString name)

(* ---- Opcode emission ---- *)

let emit (st : comp_state) (op : opcode) =
  st.ops <- st.ops @ [op]

let current_offset (st : comp_state) = List.length st.ops

(* ---- Backpatch helper ---- *)

let backpatch_jump (st : comp_state) (jmp_idx : int) =
  let target = List.length st.ops in
  st.ops <- List.mapi (fun i op ->
    if i = jmp_idx then
      match op with
      | JUMP _ -> JUMP (target - jmp_idx)
      | JUMP_IF_FALSE _ -> JUMP_IF_FALSE (target - jmp_idx)
      | _ -> op
    else op
  ) st.ops


(* ---- Extend cenv with flat frame (no nesting) ---- *)

(** Extend the current cenv frame with [names], returning the starting slot
    index and a thunk to restore the cenv. *)
let extend_cenv (st : comp_state) (names : string list) : int * (unit -> unit) =
  let current_frame, parent_frames =
    match st.cenv with
    | [] -> [], []
    | f :: rest -> f, rest
  in
  let start_slot = List.length current_frame in
  st.cenv <- (current_frame @ names) :: parent_frames;
  let restore () =
    st.cenv <- current_frame :: parent_frames
  in
  (start_slot, restore)
let rec emit_thunk_region ?type_ann:(ta=None) ?thunk_loc:(tl=None) (st : comp_state) (e : expr) : int =
  let jmp_idx = current_offset st in
  emit st (JUMP 0);  (* placeholder, patched after body *)
  let body_start = current_offset st in
  compile_expr st e true;
  emit st RETURN;
  backpatch_jump st jmp_idx;
  emit st (MAKE_THUNK (body_start, ta, tl));
  body_start

(* ---- Emit a closure/fexpr region (body + JUMP-around + MAKE_CLOSURE/MAKE_FEXPR) ---- *)

and emit_closure_region ?(name=None) (st : comp_state) (params : string list) (body : expr) (is_fexpr : bool) : int =
  let jmp_idx = current_offset st in
  emit st (JUMP 0);
  let body_start = current_offset st in
  let saved_cenv = st.cenv in
  st.cenv <- params :: st.cenv;
  compile_expr st body true;
  emit st RETURN;
  st.cenv <- saved_cenv;
  backpatch_jump st jmp_idx;
  Hashtbl.add st.nparams_of body_start (List.length params);
  Hashtbl.add st.param_names_of body_start params;
  (match name with Some n -> Hashtbl.add st.closure_names_of body_start n | None -> ());
  if is_fexpr then
    emit st (MAKE_FEXPR (body_start, List.length params))
  else
    emit st (MAKE_CLOSURE (body_start, List.length params));
  body_start

(* ---- Lexical resolution ---- *)

and resolve (cenv : cenv) (name : string) : [`Local of int * int | `Global] =
  let rec walk depth = function
    | [] -> `Global
    | frame :: rest ->
        let rec scan idx = function
          | [] -> walk (depth + 1) rest
          | n :: ns -> if n = name then `Local (depth, idx) else scan (idx + 1) ns
        in
        scan 0 frame
  in
  walk 0 cenv

(* ---- Compile an expression ---- *)

and compile_expr (st : comp_state) (e : expr) (tail : bool) : unit =
  match e with

  | ELiteral v ->
      emit st (PUSH (intern st v))

  | ESymbol name ->
      (match resolve st.cenv name with
       | `Local (depth, slot) -> emit st (LOAD_LOCAL (depth, slot))
       | `Global -> emit st (LOAD_GLOBAL (intern_name st name)));
      emit st FORCE

  | EIf (cond, then_e, else_e) ->
      compile_expr st cond false;
      emit st FORCE;
      let jmp_false_idx = current_offset st in
      emit st (JUMP_IF_FALSE 0);
      compile_expr st then_e tail;
      let jmp_end_idx = current_offset st in
      emit st (JUMP 0);
      let else_start = current_offset st in
      backpatch_jump st jmp_false_idx;
      compile_expr st else_e tail;
      backpatch_jump st jmp_end_idx
  | ELet (bindings, body) ->
      let names = List.map fst bindings in
      if st.cenv = [] then begin
        (* Top-level let: bind as globals so eval-pp/REPL can see them. *)
        List.iter (fun (_, binding_expr) ->
          ignore (emit_thunk_region st binding_expr)
        ) bindings;
        (* Stack has thunks in source order; store in reverse so names map
           correctly to their values. *)
        List.iter (fun name ->
          emit st (STORE_GLOBAL (intern_name st name))
        ) (List.rev names);
        compile_expr st body tail
      end else begin
        let start_slot, restore = extend_cenv st names in
        (* Emit thunk regions for each binding expression *)
        List.iter (fun (_, binding_expr) ->
          ignore (emit_thunk_region st binding_expr)
        ) bindings;
        (* Store into locals at consecutive slots.  Thunks were pushed in
           source order, so the top of the stack is the last binding; store
           in reverse order to keep source-order slot assignment. *)
        let n = List.length bindings in
        List.iteri (fun i _ ->
          emit st (STORE_LOCAL (start_slot + (n - 1 - i)))
        ) (List.rev bindings);
        compile_expr st body tail;
        restore ()
      end

  | EFn (params, body) ->
      ignore (emit_closure_region st params body false)

  | EApply (fn_expr, arg_exprs) ->
      compile_expr st fn_expr false;
      List.iter (fun arg -> ignore (emit_thunk_region st arg)) arg_exprs;
      if tail then
        emit st (TAIL_CALL (List.length arg_exprs))
      else
        emit st (CALL (List.length arg_exprs))

  | EQuote e ->
      emit st (PUSH (intern st (quote_to_value e)))

  | EForce e ->
      compile_expr st e false;
      emit st FORCE

  | EDelay e ->
      ignore (emit_thunk_region st e)
  | EDo exprs ->
      let is_top_level = (st.cenv = []) in
      (* Pass 1: collect defs *)
      let def_infos = ref [] in
      let slot_counter = ref 0 in
      let names_to_add = ref [] in
      List.iter (fun sub ->
        match sub with
        | EDef (name, _, _) ->
            def_infos := {name; is_fexpr=false; slot= !slot_counter} :: !def_infos;
            names_to_add := name :: !names_to_add;
            if not is_top_level then incr slot_counter
        | EDefFexpr (name, _, _) ->
            def_infos := {name; is_fexpr=true; slot= !slot_counter} :: !def_infos;
            names_to_add := name :: !names_to_add;
            Hashtbl.add st.fexpr_names name true;
            if not is_top_level then incr slot_counter
        | _ -> ()
      ) exprs;
      let start_slot, restore =
        if is_top_level || !names_to_add = [] then (0, fun () -> ())
        else extend_cenv st (List.rev !names_to_add)
      in
      let def_map = Hashtbl.create 16 in
      List.iter (fun di -> Hashtbl.add def_map di.name {di with slot = start_slot + di.slot}) !def_infos;
      (* Pass 2: compile each sub-expression *)
      let rec compile_subs = function
        | [] -> ()
        | [last] -> compile_expr st last tail
        | (EDef (name, params, body)) :: rest ->
            ignore (emit_closure_region ~name:(Some name) st params body false);
            if is_top_level then
              emit st (STORE_GLOBAL (intern_name st name))
            else
              (match Hashtbl.find_opt def_map name with
               | Some di -> emit st (STORE_LOCAL di.slot)
               | None -> failwith ("compiler: def " ^ name ^ " not found"));
            compile_subs rest
        | (EDefFexpr (name, params, body)) :: rest ->
            ignore (emit_closure_region ~name:(Some name) st params body true);
            if is_top_level then
              emit st (STORE_GLOBAL (intern_name st name))
            else
              (match Hashtbl.find_opt def_map name with
               | Some di -> emit st (STORE_LOCAL di.slot)
               | None -> failwith ("compiler: def-fexpr " ^ name ^ " not found"));
            compile_subs rest
        | (EImport mod_expr) :: rest ->
            compile_expr st mod_expr false;
            emit st FORCE;
            emit st IMPORT;
            emit st POP;
            compile_subs rest
        | (ELoad path) :: rest ->
            emit st (LOAD_FILE (intern_name st path));
            compile_subs rest
        | (ELoadModule path) :: rest ->
            emit st (LOAD_MODULE_FILE (intern_name st path));
            (* Statement position: tree-walker merges the module's bindings
               into the enclosing env (EDo/eval_expressions); IMPORT matches
               (D20), then POP discards the statement's value. *)
            emit st IMPORT;
            emit st POP;
            compile_subs rest
        | e :: rest ->
            compile_expr st e false;
            emit st FORCE;
            emit st POP;
            compile_subs rest
      in
      compile_subs exprs;
      restore ()

  | EEffect (caps_expr, body) ->
      compile_expr st caps_expr false;
      emit st FORCE;
      emit st ENTER_EFFECT;
      (* Body compiled NON-tail (was [tail]) so control returns to run
         EXIT_EFFECT; a tail call in the body would frame-swap past EXIT and
         leak the capability scope (D9). The tree-walker holds its frame open
         across the body to restore [current_capabilities] (evaluator.ml
         EEffect), so this is the matching dynamic extent, not a TCO loss. *)
      compile_expr st body false;
      emit st EXIT_EFFECT

  | EDef (name, params, body) ->
      ignore (emit_closure_region ~name:(Some name) st params body false);
      emit st (STORE_GLOBAL (intern_name st name));
      if tail && st.cenv = [] then
        emit st (LOAD_GLOBAL (intern_name st name))
  | EDefFexpr (name, params, body) ->
      ignore (emit_closure_region ~name:(Some name) st params body true);
      emit st (STORE_GLOBAL (intern_name st name));
      Hashtbl.add st.fexpr_names name true;
      if tail && st.cenv = [] then
        emit st (LOAD_GLOBAL (intern_name st name))


  | EPerform (name, arg_exprs) ->
      List.iter (fun arg -> ignore (emit_thunk_region st arg)) arg_exprs;
      emit st (PERFORM (intern_name st name, List.length arg_exprs))

  | EWithHandler (handlers, body) ->
      List.iter (fun (name, handler_expr) ->
        emit st (PUSH (intern st (VString name)));
        (* Tree-walker: the handler value is [force (eval handler_expr env)] —
           the function itself, APPLIED to the effect args at perform time
           (evaluator.ml EWithHandler/perform_effect). The old 0-param
           emit_closure_region wrapper made [perform] return the fn instead of
           running it. Compile the handler expr directly and force it. *)
        compile_expr st handler_expr false;
        emit st FORCE
      ) handlers;
      emit st (PUSH_HANDLER (List.length handlers));
      (* Body NON-tail (was [tail]) so control returns to run POP_HANDLER;
         a tail call would frame-swap past POP and leak the handler (D9). *)
      compile_expr st body false;
      emit st POP_HANDLER

  | EImport mod_expr ->
      compile_expr st mod_expr false;
      emit st FORCE;
      emit st IMPORT

  | EModule exprs ->
      let saved_cenv = st.cenv in
      st.cenv <- [];
      let count = ref 0 in
      List.iter (fun sub ->
        match sub with
        | EDef (name, params, body) ->
            emit st (PUSH (intern st (VString name)));
            ignore (emit_closure_region ~name:(Some name) st params body false);
            incr count
        | EDefFexpr (name, params, body) ->
            emit st (PUSH (intern st (VString name)));
            Hashtbl.add st.fexpr_names name true;
            ignore (emit_closure_region ~name:(Some name) st params body true);
            incr count
        | EImport _ ->
            (* Evaluated for its side effects like the tree-walker
               (evaluator.ml EModule); IMPORT pushes the module value,
               which is not part of the module under construction. *)
            compile_expr st sub false;
            emit st POP
        | _ ->
            (* Tree-walker evaluates every module child for side effects
               (evaluator.ml EModule); do the same, discarding the value. *)
            compile_expr st sub false;
            emit st FORCE;
            emit st POP
      ) exprs;
      st.cenv <- saved_cenv;
      emit st (MAKE_MODULE !count)


  | ELoad path ->
      emit st (LOAD_FILE (intern_name st path))
  | ELoadModule path ->
      emit st (LOAD_MODULE_FILE (intern_name st path))

  | ELocated (loc, ETyped (e, ty)) ->
      ignore (emit_thunk_region st e ~type_ann:(Some ty) ~thunk_loc:(Some loc))
  | ETyped (e, ty) ->
      ignore (emit_thunk_region st e ~type_ann:(Some ty))
  | ELocated (_, e) ->
      compile_expr st e tail
  | EIsland (uri, _) ->
      emit st (LOAD_FILE (intern_name st uri))
  | EWithConfig (map_expr, body) ->
      compile_expr st map_expr false;
      emit st FORCE;
      emit st PUSH_CONFIG;
      (* Body NON-tail (was [tail]) so control returns to run POP_CONFIG;
         a tail call would frame-swap past POP and leak the config scope
         (D9). Matches the tree-walker's dynamic extent (evaluator.ml
         EWithConfig restores [config_stack] after the body). *)
      compile_expr st body false;
      emit st POP_CONFIG
  | EConfig (key_expr, default_opt) ->
      compile_expr st key_expr false;
      emit st FORCE;
      emit st READ_CONFIG;
      (match default_opt with
       | Some d ->
           emit st DUP;
           let jmp_false = current_offset st in
           emit st (JUMP_IF_FALSE 0);
           let jmp_end = current_offset st in
           emit st (JUMP 0);
           backpatch_jump st jmp_false;
           emit st POP;
           ignore (emit_thunk_region st d);
           emit st FORCE;
           backpatch_jump st jmp_end
       | None -> ())

  | ELetStar (bindings, body) ->
      let rec compile_sequential saved_frame = function
        | [] ->
            compile_expr st body tail;
            st.cenv <- saved_frame :: (match st.cenv with [] -> [] | _ :: rest -> rest)
        | ((name, e) :: rest) ->
            ignore (emit_thunk_region st e);
            let _, restore = extend_cenv st [name] in
            emit st (STORE_LOCAL 0);
            compile_sequential saved_frame rest
      in
      let saved_frame = match st.cenv with [] -> [] | f :: _ -> f in
      compile_sequential saved_frame bindings

(* ---- Compile a program ---- *)

let compile_program (exprs : expr list) : bytecode =
  let st = fresh_comp_state () in
  let rec compile_all = function
    | [] -> ()
    | [last] -> compile_expr st last true
    | e :: rest ->
        (* Non-last: compile non-tail (CALL not TAIL_CALL), then POP result *)
        (match e with
         | ELoadModule _ ->
             (* Tree-walker merges a statement-position load-module's
                bindings into the top-level env (eval_expressions); emit an
                explicit IMPORT to match, now that LOAD_MODULE_FILE itself
                no longer merges (D20). *)
             compile_expr st e true;
             emit st IMPORT;
             emit st POP
         | EImport _ ->
             (* compile_expr's EImport ends in IMPORT, which pushes the
                module value; discard it in statement position. *)
             compile_expr st e true;
             emit st POP
         | EDef _ | EDefFexpr _ | ELoad _ ->
             (* Defs consume their own result (STORE_GLOBAL), no POP needed *)
             compile_expr st e true
         | _ ->
             compile_expr st e false;
             emit st POP);
        compile_all rest
  in
  compile_all exprs;
  emit st HALT;
  {
    consts = Array.of_list st.consts;
    code = Array.of_list st.ops;
    nparams_of = st.nparams_of;
    param_names_of = st.param_names_of;
    closure_names_of = st.closure_names_of;
  }

let finish_comp_state (st : comp_state) : bytecode =
  emit st HALT;
  {
    consts = Array.of_list st.consts;
    code = Array.of_list st.ops;
    nparams_of = st.nparams_of;
    param_names_of = st.param_names_of;
    closure_names_of = st.closure_names_of;
  }

(* Register with primitives *)
let () =
  Primitives.compiler_finish_ref := finish_comp_state
