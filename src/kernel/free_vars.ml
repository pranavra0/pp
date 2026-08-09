open Core_model

(* The persistent node key resolves exactly the free symbols to their value
   hashes, so a node
   depends on the definitions it actually uses — not on the whole ambient
   environment (rebinding an unrelated global must not re-key it). Over-approx is
   sound (fewer hits); under-approx is not, so binding forms are handled
   conservatively. *)
module SS = Set.Make(String)

let free_vars (e : expr) : SS.t =
  let add_all names b = List.fold_left (fun acc n -> SS.add n acc) b names in
  (* names a `do`/`module` block binds for its siblings (defs, incl. located) *)
  let block_binders exprs =
    List.filter_map (function
      | EDef (n, _, _) | EDefNode (n, _, _) | EDefValue (n, _) -> Some n
      | ELocated (_, (EDef (n, _, _) | EDefNode (n, _, _) | EDefValue (n, _))) -> Some n
      | _ -> None) exprs
  in
  let rec fv bound e =
    match e with
    | EApply (ESymbol "\000needs-value", _) -> SS.empty
    | ELiteral _ | EQuote _ | ELoad _ | ELoadModule _ | EIsland _ -> SS.empty
    | ESymbol s -> if SS.mem s bound then SS.empty else SS.singleton s
    | EIf (c, t, f) -> SS.union (fv bound c) (SS.union (fv bound t) (fv bound f))
    | ELet (binds, body) ->
        let bound' = add_all (List.map fst binds) bound in
        let rhs =
          List.fold_left (fun vars (_, expression) ->
            SS.union vars (fv bound' expression)) SS.empty binds
        in
        SS.union rhs (fv bound' body)
    | ELetStar (binds, body) ->
        let rec bind vars current_bound = function
          | [] -> SS.union vars (fv current_bound body)
          | (name, expression) :: rest ->
              bind (SS.union vars (fv current_bound expression))
                (SS.add name current_bound) rest
        in
        bind SS.empty bound binds
    | EFn (params, body) -> fv (add_all params bound) body
    | EApply (f, args) ->
        List.fold_left (fun a e -> SS.union a (fv bound e)) (fv bound f) args
    | EForce e | EDelay e | ENode e -> fv bound e
    | EWithCaps (caps, body) ->
        SS.union (fv bound caps) (fv bound body)
    | EPerform (_, args) ->
        List.fold_left (fun a e -> SS.union a (fv bound e)) SS.empty args
    | EWithHandler (handlers, body) ->
        let hs = List.fold_left (fun a (_, e) -> SS.union a (fv bound e)) SS.empty handlers in
        SS.union hs (fv bound body)
    | EDef (name, params, body) | EDefNode (name, params, body) ->
        fv (add_all params (SS.add name bound)) body
    | EDefValue (_, e) ->
        (* Whole-block letrec* scope is handled by block_binders; a
           self-reference in the RHS is a referenced-before-definition error
           at runtime, never a dependency on an outer binding. *)
        fv bound e
    | EDo exprs | EModule exprs ->
        let bound' = add_all (block_binders exprs) bound in
        List.fold_left (fun a e -> SS.union a (fv bound' e)) SS.empty exprs
    | EImport mod_expr -> fv bound mod_expr
    | EWithConfig (m, body) -> SS.union (fv bound m) (fv bound body)
    | EConfig (k, d) ->
        SS.union (fv bound k) (match d with Some e -> fv bound e | None -> SS.empty)
    | ETyped (e, _) -> fv bound e
    | ELocated (_, e) -> fv bound e
    | EMatch (scrutinee, arms) ->
        let rec pat_vars p = match p with
          | PVariable s -> SS.singleton s
          | PList (pats, rest) ->
              let pv = List.fold_left (fun a p -> SS.union a (pat_vars p)) SS.empty pats in
              (match rest with Some r -> SS.union pv (pat_vars r) | None -> pv)
          | PTagged (_, pats) ->
              List.fold_left (fun a p -> SS.union a (pat_vars p)) SS.empty pats
          | PLiteral _ | PWildcard -> SS.empty
        in
        let scrut_fv = fv bound scrutinee in
        let arms_fv = List.fold_left (fun a (pattern, guard, body) ->
          let arm_bound = SS.union bound (pat_vars pattern) in
          let gfv = match guard with Some g -> fv arm_bound g | None -> SS.empty in
          SS.union a (SS.union gfv (fv arm_bound body))) SS.empty arms in
        SS.union scrut_fv arms_fv
  in
  fv SS.empty e

let node_free_vars = free_vars
