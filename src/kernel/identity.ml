open Core_model


(* THE canonical float spelling — bit-exact via %h (so two doubles that differ
   anywhere in their bits hash and encode differently; string_of_float's ~12
   significant digits could collide two distinct doubles into one content key
   and serve a wrong cached result), with nan/inf/-inf as fixed tokens (NaN
   payloads deliberately merge). Shared by hash_value below and the store
   codec (Codec.encode_float) so content identity and on-disk bytes can never
   disagree about whether two floats are the same value. *)
let canonical_float_string (f : float) : string =
  if f <> f then "nan"
  else if f = Float.infinity then "inf"
  else if f = Float.neg_infinity then "-inf"
  else Printf.sprintf "%h" f

let rec hash_expr (e : expr) : string =
  match e with
  | ELiteral v -> Hasher.hash_concat ["lit"; hash_value v]
  | ESymbol s -> Hasher.hash_concat ["sym"; s]
  | EIf (c, t, f) -> Hasher.hash_concat ["if"; hash_expr c; hash_expr t; hash_expr f]
  | ELet (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        Hasher.hash_concat ["let_bind"; n; hash_expr e]
      ) (List.sort (fun (n1, _) (n2, _) -> String.compare n1 n2) bindings) in
      Hasher.hash_concat ("let" :: bparts @ [hash_expr body])
  | EFn (params, body) ->
      Hasher.hash_concat ["fn"; Hasher.hash_concat ("params" :: params); hash_expr body]
  | EApply (fn, args) ->
      let arg_hashes = List.map hash_expr args in
      Hasher.hash_concat ("apply" :: hash_expr fn :: arg_hashes)
  | EQuote e -> Hasher.hash_concat ["quote"; hash_expr e]
  | EForce e -> Hasher.hash_concat ["force"; hash_expr e]
  | EWithCaps (caps, body) ->
      Hasher.hash_concat ["with_caps"; hash_expr caps; hash_expr body]
  | EPerform (name, args) ->
      let arg_hashes = List.map hash_expr args in
      Hasher.hash_concat ("perform" :: name :: arg_hashes)
  | EWithHandler (handlers, body) ->
      let hparts = List.map (fun (n, e) ->
        Hasher.hash_concat ["handler"; n; hash_expr e]
      ) handlers in
      Hasher.hash_concat ("with_handler" :: hparts @ [hash_expr body])
  | EDelay e -> Hasher.hash_concat ["delay"; hash_expr e]
  | ENode e -> Hasher.hash_concat ["node"; hash_expr e]
  | EDefNode (name, params, body) ->
      Hasher.hash_concat ["defnode"; name; Hasher.hash_concat ("params" :: params); hash_expr body]
  | EDo exprs ->
      Hasher.hash_concat ("do" :: List.map hash_expr exprs)
  | EDef (name, params, body) ->
      Hasher.hash_concat ["def"; name; Hasher.hash_concat ("params" :: params); hash_expr body]
  | EDefValue (name, e) ->
      Hasher.hash_concat ["def-value"; name; hash_expr e]
  | ELetStar (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        Hasher.hash_concat ["let_star_bind"; n; hash_expr e]
      ) bindings in
      Hasher.hash_concat ("let_star" :: bparts @ [hash_expr body])
  | EModule exprs ->
      Hasher.hash_concat ("module" :: List.map hash_expr exprs)
  | EImport mod_expr ->
      Hasher.hash_concat ["import"; hash_expr mod_expr]
  | ELoad path ->
      Hasher.hash_concat ["load"; path]
  | ELoadModule path ->
      Hasher.hash_concat ["load_module"; path]
  | EIsland (uri, pin) ->
      (* Frame the pin option so an unpinned island (None) can never share a
         key with one pinned to the empty string (Some ""): a raw-string
         join `Some p -> p | None -> ""` would conflate them, a content
         collision (island "u" "" and island "u" quote to distinct values —
         VString "" vs VNil — yet would hash identically). Caught by the
         kernel-properties injectivity property. *)
      let pin_part = match pin with Some p -> Hasher.hash_concat ["pin"; p] | None -> "nopin" in
      Hasher.hash_concat ["island"; uri; pin_part]
  | EWithConfig (map_expr, body) ->
      Hasher.hash_concat ["with_config"; hash_expr map_expr; hash_expr body]
  | EConfig (key_expr, default) ->
      Hasher.hash_concat ["config"; hash_expr key_expr; (match default with Some d -> hash_expr d | None -> "")]
  | ETyped (e, ty) ->
      Hasher.hash_concat ["typed"; hash_expr e; hash_expr ty]
  | ELocated ((file, line), e) ->
      Hasher.hash_concat ["located"; file; string_of_int line; hash_expr e]
  | EMatch (scrutinee, arms) ->
      let arm_hashes = List.map (fun (p, guard, body) ->
        match guard with
        | None -> Hasher.hash_concat ["arm"; hash_pattern p; hash_expr body]
        | Some g -> Hasher.hash_concat ["arm-guard"; hash_pattern p; hash_expr g; hash_expr body]
      ) arms in
      Hasher.hash_concat ("match" :: hash_expr scrutinee :: arm_hashes)

and hash_pattern (p : pattern) : string =
  match p with
  | PLiteral v -> Hasher.hash_concat ["p_lit"; hash_value v]
  | PVariable s -> Hasher.hash_concat ["p_var"; s]
  | PWildcard -> "p_wild"
  | PList (pats, rest) ->
      (* Frame the sub-pattern list through Hasher.hash_concat rather than a
         delimiter-free `String.concat ""`: the latter would be injective only by
         the accident that every sub-hash is exactly 64 chars, so [ab] and [a;b]
         could alias the moment that invariant slipped. *)
      let ph = Hasher.hash_concat (List.map hash_pattern pats) in
      let rh = match rest with Some r -> hash_pattern r | None -> "nil" in
      Hasher.hash_concat ["p_list"; ph; rh]
  | PTagged (tag, pats) ->
      let ph = Hasher.hash_concat (List.map hash_pattern pats) in
      Hasher.hash_concat ["p_tagged"; tag; ph]

and hash_value (v : value) : string =
  let rec hash_val v =
    match v with
    | VThunk t ->
        (match t.thunk_hash with
         | Some h -> h  (* O(1): use precomputed content-addressable hash *)
         | None ->
             Hasher.hash_concat ["thunk"; hash_expr t.thunk_expr; t.thunk_env.env_hash; t.config_hash])
    | VNil -> Hasher.hash_string "nil"
    | VBool true -> Hasher.hash_string "bool:true"
    | VBool false -> Hasher.hash_string "bool:false"
    | VInt n -> Hasher.hash_concat ["int"; string_of_int n]
    | VFloat f -> Hasher.hash_concat ["float"; canonical_float_string f]
    | VString s -> Hasher.hash_concat ["string"; s]
    | VKeyword k -> Hasher.hash_concat ["keyword"; k]
    | VSymbol s -> Hasher.hash_concat ["symbol"; s]
    | VPair (car, cdr) ->
        Hasher.hash_concat ["pair"; hash_val car; hash_val cdr]
    | VVector vs ->
        let parts = Array.to_list (Array.map hash_val vs) in
        Hasher.hash_concat ("vector" :: parts)
    | VMap kvs ->
        let hashed = List.map (fun (k, v) -> (hash_val k, hash_val v)) kvs in
        let sorted = List.sort (fun (kh1,_) (kh2,_) ->
          String.compare kh1 kh2) hashed in
        let parts = List.map (fun (kh, vh) -> Hasher.hash_concat [kh; vh]) sorted in
        Hasher.hash_concat ("map" :: parts)
    | VSet vs ->
        let sorted = List.sort String.compare (List.map hash_val vs) in
        Hasher.hash_concat ("set" :: sorted)
    | VClosure { fn_name; params; body; env; is_node } ->
        let name_part = match fn_name with Some n -> n | None -> "anon" in
        let kind = if is_node then "node-closure" else "closure" in
        Hasher.hash_concat [kind; name_part;
                     Hasher.hash_concat ("params" :: params);
                     hash_expr body;
                     (!env).env_hash]
    | VBuiltin (name, _) ->
        Hasher.hash_concat ["builtin"; name]
    | VCapability cap ->
        Capability.hash cap
    | VEnvMap bindings ->
        let sorted = List.sort (fun (a,_) (b,_) -> String.compare a b) bindings in
        let parts = List.map (fun (name, v) ->
          Hasher.hash_concat [name; hash_val v]
        ) sorted in
        Hasher.hash_concat ("envmap" :: parts)
    | VSealed bytes ->
        Hasher.hash_concat ["sealed"; bytes]
  in
  hash_val v
