open Core_model
let string_of_value = Presentation.string_of_value
let value_list_opt = Presentation.value_list_opt

let rec quote_to_value (e : expr) : value =
  match e with
  | ELiteral v -> v
  | ESymbol s -> VSymbol s
  | EIf (cond, then_e, else_e) ->
      VPair (VSymbol "if",
        VPair (quote_to_value cond,
          VPair (quote_to_value then_e,
            VPair (quote_to_value else_e, VNil))))
  | ELet (bindings, body) ->
      let qbindings = List.fold_right (fun (n, e) acc ->
        VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)
      ) bindings VNil in
      VPair (VSymbol "let",
        VPair (qbindings,
          VPair (quote_to_value body, VNil)))
  | EFn (params, body) ->
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
  | ENode e -> VPair (VSymbol "node", VPair (quote_to_value e, VNil))
  | EDefNode (name, params, body) ->
      VPair (VSymbol "defnode",
        VPair (VSymbol name,
          VPair (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil,
            VPair (quote_to_value body, VNil))))
  | EDo exprs ->
      let qexprs = List.map quote_to_value exprs in
      VPair (VSymbol "do", List.fold_right (fun a acc -> VPair (a, acc)) qexprs VNil)
  | EDef (name, params, body) ->
      VPair (VSymbol "def",
        VPair (VSymbol name,
          VPair (List.fold_right (fun p acc -> VPair (VSymbol p, acc)) params VNil,
            VPair (quote_to_value body, VNil))))
  | EDefValue (name, e) ->
      VPair (VSymbol "def",
        VPair (VSymbol name, VPair (quote_to_value e, VNil)))
  | ELetStar (bindings, body) ->
      VPair (VSymbol "let*",
        VPair (List.fold_right (fun (n, e) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value e, VNil)), acc)) bindings VNil,
          VPair (quote_to_value body, VNil)))
  | EWithCaps (caps, body) ->
      VPair (VSymbol "with-caps", VPair (quote_to_value caps, VPair (quote_to_value body, VNil)))
  | EPerform (name, args) ->
      let qargs = List.map quote_to_value args in
      VPair (VSymbol "perform",
        VPair (VSymbol name, List.fold_right (fun a acc -> VPair (a, acc)) qargs VNil))
  | EWithHandler (handlers, body) ->
      VPair (VSymbol "with-handler",
        VPair (List.fold_right (fun (n, h) acc ->
          VPair (VPair (VSymbol n, VPair (quote_to_value h, VNil)), acc)) handlers VNil,
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
  | EIsland (uri, pin) ->
      let pin_v = match pin with Some p -> VString p | None -> VNil in
      VPair (VSymbol "island",
        VPair (VString uri, VPair (pin_v, VNil)))
  | EWithConfig (map_expr, body) ->
      VPair (VSymbol "with-config",
        VPair (quote_to_value map_expr, VPair (quote_to_value body, VNil)))
  | EConfig (key_expr, default) ->
      let default_v = match default with Some d -> quote_to_value d | None -> VNil in
      VPair (VSymbol "config",
        VPair (quote_to_value key_expr, VPair (default_v, VNil)))
  | ETyped (e, ty) ->
      VPair (VSymbol ":",
        VPair (quote_to_value e, VPair (quote_to_value ty, VNil)))
  | ELocated (_, e) ->
      quote_to_value e
  | EMatch (scrutinee, arms) ->
      let q_arms = List.fold_right (fun (p, guard, body) acc ->
        let q_pat = quote_pattern p in
        (* A guardless arm quotes to a 2-list (pat body); a guarded arm
           to a 3-list (pat guard body). value_to_expr splits on length. *)
        let q_arm = match guard with
          | None -> VPair (q_pat, VPair (quote_to_value body, VNil))
          | Some g ->
              VPair (q_pat, VPair (quote_to_value g, VPair (quote_to_value body, VNil)))
        in
        VPair (q_arm, acc)
      ) arms VNil in
      VPair (VSymbol "match",
        VPair (quote_to_value scrutinee, VPair (q_arms, VNil)))

and quote_pattern (p : pattern) : value =
  match p with
  | PLiteral v -> VPair (VSymbol "lit", VPair (v, VNil))
  | PVariable s -> VPair (VSymbol "var", VPair (VString s, VNil))
  | PWildcard -> VSymbol "_"
  | PList (pats, rest) ->
      let q_pats = List.map quote_pattern pats in
      let q_rest = match rest with Some r -> quote_pattern r | None -> VNil in
      VPair (VSymbol "list",
        VPair (List.fold_right (fun p acc -> VPair (p, acc)) q_pats VNil,
               VPair (q_rest, VNil)))
  | PTagged (tag, pats) ->
      let q_pats = List.map quote_pattern pats in
      VPair (VSymbol "tagged",
        VPair (VString tag,
               List.fold_right (fun p acc -> VPair (p, acc)) q_pats VNil))

let rec value_to_expr (v : value) : expr =
  match v with
  | VNil | VBool _ | VInt _ | VFloat _ | VString _ | VKeyword _ -> ELiteral v
  | VSymbol s -> ESymbol s
  | VVector vs ->
      EApply (ESymbol "vector", Array.to_list (Array.map value_to_expr vs))
  | VMap kvs ->
      EApply (ESymbol "hash-map",
              List.concat_map (fun (k, v) -> [value_to_expr k; value_to_expr v]) kvs)
  | VSet vs ->
      EApply (ESymbol "hash-set", List.map value_to_expr vs)
  | VPair _ ->
      (match value_list_opt v with
       | Some items -> expr_of_list items
       | None ->
           failwith "value_to_expr: cannot convert an improper (dotted) list to syntax")
  | VClosure _ ->
      failwith "value_to_expr: cannot convert a closure to syntax"
  | VBuiltin (name, _) ->
      failwith (Printf.sprintf "value_to_expr: cannot convert builtin '%s' to syntax" name)
  | VCapability _ ->
      failwith "value_to_expr: cannot convert a capability to syntax"
  | VThunk _ ->
      failwith "value_to_expr: cannot convert an unevaluated thunk to syntax"
  | VEnvMap _ ->
      failwith "value_to_expr: cannot convert a module (env-map) to syntax"
  | VSealed _ ->
      failwith "value_to_expr: cannot convert a sealed value to syntax"

and symbol_name (v : value) : string =
  match v with
  | VSymbol s -> s
  | VKeyword s -> s
  | other -> failwith (Printf.sprintf
      "value_to_expr: expected a symbol, got %s" (string_of_value other))

and symbols_of_values (items : value list) : string list =
  List.map (function
    | VSymbol s -> s
    | other -> failwith (Printf.sprintf
        "value_to_expr: expected a symbol in a parameter list, got %s"
        (string_of_value other)))
    items

and symbols_of_list (v : value) : string list =
  match value_list_opt v with
  | Some items -> symbols_of_values items
  | None -> failwith "value_to_expr: malformed parameter list"

and symbols_of_array (arr : value array) : string list =
  symbols_of_values (Array.to_list arr)

(* A binding list for let/let*/with-handler. TWO shapes are accepted, because
   two different, equally natural routes produce them:
   - quote_to_value's OWN internal encoding — a list of 2-element (name val)
     sublists — is what `(quote (let [x 1] x))` reflects to, so a macro that
     passes a captured let-form through must round-trip it.
   - a flat, alternating-elements VECTOR — name1 val1 name2 val2 ... — is
     what a macro naturally builds by quasiquoting the SAME bracket syntax
     `[x 1]` a human would write directly (reader.ml parse_binding_vector /
     parse_with_handler): `` `(let [,ga ,val] body) `` quasiquotes a vector
     literal, which reader.ml's parse_qq_vector turns into a flat
     `(vector ...)` call, never a list of pairs. Both must work. *)
and binding_pairs (v : value) : (string * expr) list =
  match v with
  | VVector arr ->
      let rec pair = function
        | [] -> []
        | [odd] -> failwith (Printf.sprintf
            "value_to_expr: odd element in binding vector: %s" (string_of_value odd))
        | n :: ve :: rest -> (symbol_name n, value_to_expr ve) :: pair rest
      in
      pair (Array.to_list arr)
  | _ ->
      (match value_list_opt v with
       | Some items ->
           List.map (fun item ->
             match value_list_opt item with
             | Some [n; ve] -> (symbol_name n, value_to_expr ve)
             | _ -> failwith "value_to_expr: malformed binding pair")
             items
       | None -> failwith "value_to_expr: malformed binding list")

(* [items] is always non-empty (it came from a VPair, which has at least a
   car) — the shape dispatch mirrors quote_to_value's construction sites,
   matching on (head symbol, item count/shape). Any shape that does not
   match falls through to ordinary application (the reader's own fallback
   for an unrecognized car symbol). *)
and expr_of_list (items : value list) : expr =
  match items with
  | [VSymbol "if"; c; t; f] -> EIf (value_to_expr c, value_to_expr t, value_to_expr f)
  | [VSymbol "let"; bindings; body] -> ELet (binding_pairs bindings, value_to_expr body)
  | [VSymbol "let*"; bindings; body] -> ELetStar (binding_pairs bindings, value_to_expr body)
  | [VSymbol "fn"; VVector params; body] ->
      EFn (symbols_of_array params, value_to_expr body)
  | [VSymbol "quote"; e] -> EQuote (value_to_expr e)
  | [VSymbol "force"; e] -> EForce (value_to_expr e)
  | [VSymbol "delay"; e] -> EDelay (value_to_expr e)
  | [VSymbol "node"; e] -> ENode (value_to_expr e)
  (* defnode/def, quote_to_value's OWN 4-item encoding: name and params kept
     as SEPARATE items (this is what `(quote (def (f x) x))` reflects to). *)
  | [VSymbol "defnode"; VSymbol name; params; body] ->
      EDefNode (name, symbols_of_list params, value_to_expr body)
  | [VSymbol "def"; VSymbol name; params; body] ->
      EDef (name, symbols_of_list params, value_to_expr body)
  (* def, 3-item value-binding form: `(def name value)`. Checked BEFORE the
     natural merged-list case below so a bare-symbol 2nd item is never
     mistaken for a one-element param list. *)
  | [VSymbol "def"; VSymbol name; value] ->
      EDefValue (name, value_to_expr value)
  (* defnode/def, the NATURAL quasiquote/surface-syntax shape: name and
     params MERGED into one list, exactly mirroring `(def (name p...)
     body)` / `(defnode (name p...) body)` source syntax — reader.ml's
     quasiquote list desugaring (parse_qq_list) conses every element
     uniformly, with no def-specific special-casing, so
     `` `(def (,name ,@params) ,body) `` produces exactly this shape. A
     macro author writing "the way they'd write ordinary code" needs this
     to work, not just quote_to_value's own decomposed encoding. *)
  | [VSymbol "defnode"; combined; body] ->
      (match value_list_opt combined with
       | Some (name_v :: params) ->
           EDefNode (symbol_name name_v, symbols_of_values params, value_to_expr body)
       | _ -> failwith "value_to_expr: malformed defnode form")
  | [VSymbol "def"; combined; body] ->
      (match value_list_opt combined with
       | Some (name_v :: params) ->
           EDef (symbol_name name_v, symbols_of_values params, value_to_expr body)
       | _ -> failwith "value_to_expr: malformed def form")
  | [VSymbol "with-caps"; c; b] -> EWithCaps (value_to_expr c, value_to_expr b)
  | (VSymbol "perform") :: name_v :: args ->
      EPerform (symbol_name name_v, List.map value_to_expr args)
  | [VSymbol "with-handler"; handlers; body] ->
      EWithHandler (binding_pairs handlers, value_to_expr body)
  | (VSymbol "module") :: rest -> EModule (List.map value_to_expr rest)
  | [VSymbol "import"; e] -> EImport (value_to_expr e)
  | [VSymbol "load"; VString path] -> ELoad path
  | [VSymbol "load-module"; VString path] -> ELoadModule path
  | [VSymbol "island"; VString uri; pin] ->
      EIsland (uri, (match pin with
        | VNil -> None
        | VString p -> Some p
        | _ -> failwith "value_to_expr: island pin must be a string"))
  | [VSymbol "with-config"; m; b] -> EWithConfig (value_to_expr m, value_to_expr b)
  | [VSymbol "config"; k; d] -> EConfig (value_to_expr k, Some (value_to_expr d))
  | [VSymbol ":"; e; ty] -> ETyped (value_to_expr e, value_to_expr ty)
  | (VSymbol "do") :: rest -> EDo (List.map value_to_expr rest)
  (* match, mirroring quote_to_value's EMatch encoding one-for-one:
     `(match scrutinee ((pat1 body1) (pat2 body2) ...))` — each arm a
     2-element sublist, decoded by value_to_pattern (quote_pattern's
     inverse). Needed so a quasiquote { match ... } template
     actually reconstructs an EMatch after macro expansion, not a
     bare `(match ...)` application (the generic fallback below). *)
  | [VSymbol "match"; scrutinee; arms] ->
      (match value_list_opt arms with
       | Some arm_items ->
           let arms' = List.map (fun item ->
             match value_list_opt item with
             | Some [pat_v; body_v] ->
                 (value_to_pattern pat_v, None, value_to_expr body_v)
             | Some [pat_v; guard_v; body_v] ->
                 (value_to_pattern pat_v, Some (value_to_expr guard_v), value_to_expr body_v)
             | _ -> failwith "value_to_expr: malformed match arm")
             arm_items
           in
           EMatch (value_to_expr scrutinee, arms')
       | None -> failwith "value_to_expr: malformed match arms list")
  | fn :: args -> EApply (value_to_expr fn, List.map value_to_expr args)
  | [] -> ELiteral VNil (* unreachable: [items] always comes from a VPair *)

(* The inverse of quote_pattern: value -> pattern, one shape per case. *)
and value_to_pattern (v : value) : pattern =
  match v with
  | VSymbol "_" -> PWildcard
  | VPair (VSymbol "lit", VPair (lit, VNil)) -> PLiteral lit
  | VPair (VSymbol "var", VPair (VString s, VNil)) -> PVariable s
  | VPair (VSymbol "list", VPair (pats_v, VPair (rest_v, VNil))) ->
      let pats = match value_list_opt pats_v with
        | Some items -> List.map value_to_pattern items
        | None -> failwith "value_to_expr: malformed list pattern"
      in
      let rest = match rest_v with VNil -> None | r -> Some (value_to_pattern r) in
      PList (pats, rest)
  | VPair (VSymbol "tagged", VPair (VString tag, pats_v)) ->
      (match value_list_opt pats_v with
       | Some items -> PTagged (tag, List.map value_to_pattern items)
       | None -> failwith "value_to_expr: malformed tagged pattern")
  | other -> failwith (Printf.sprintf
      "value_to_expr: cannot convert %s to a pattern" (string_of_value other))
