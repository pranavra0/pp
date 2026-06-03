(* pp hasher — content-addressing via Digest (MD5-like, 128-bit).
   v2 should upgrade to SHA-256. *)

open Types

let hash_string (s : string) : string = Digest.string s

let hash_concat (parts : string list) : string =
  hash_string (String.concat ":" parts)

(* Forward declarations *)
let rec hash_expr (e : expr) : string = 
  match e with
  | ELiteral v -> hash_concat ["lit"; hash_value v]
  | ESymbol s -> hash_concat ["sym"; s]
  | EIf (c, t, f) -> hash_concat ["if"; hash_expr c; hash_expr t; hash_expr f]
  | ELet (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        hash_concat ["let_bind"; n; hash_expr e]
      ) bindings in
      hash_concat ("let" :: bparts @ [hash_expr body])
  | EFn (params, body) ->
      hash_concat ["fn"; hash_concat ("params" :: params); hash_expr body]
  | EApply (fn, args) ->
      let arg_hashes = List.map hash_expr args in
      hash_concat ("apply" :: hash_expr fn :: arg_hashes)
  | EQuote e -> hash_concat ["quote"; hash_expr e]
  | EForce e -> hash_concat ["force"; hash_expr e]
  | EEffect (caps, body) ->
      hash_concat ["effect"; hash_expr caps; hash_expr body]
  | EPerform (name, args) ->
      let arg_hashes = List.map hash_expr args in
      hash_concat ("perform" :: name :: arg_hashes)
  | EWithHandler (handlers, body) ->
      let hparts = List.map (fun (n, e) ->
        hash_concat ["handler"; n; hash_expr e]
      ) handlers in
      hash_concat ("with_handler" :: hparts @ [hash_expr body])
  | EDelay e -> hash_concat ["delay"; hash_expr e]
  | EDo exprs ->
      hash_concat ("do" :: List.map hash_expr exprs)
  | EDef (name, params, body) ->
      hash_concat ["def"; name; hash_concat ("params" :: params); hash_expr body]
  | EDefFexpr (name, params, body) ->
      hash_concat ["def_fexpr"; name; hash_concat ("params" :: params); hash_expr body]
  | ELetStar (bindings, body) ->
      let bparts = List.map (fun (n, e) ->
        hash_concat ["let_star_bind"; n; hash_expr e]
      ) bindings in
      hash_concat ("let_star" :: bparts @ [hash_expr body])

and hash_value (v : value) : string =
  let rec hash_val v =
    match v with
    | VThunk t ->
        (match t.thunk_status with
         | Evaluated (VClosure { fn_name; params; _ }) ->
             (* Avoid hashing the closure env to prevent cycles from recursion *)
             hash_concat ["thunk_closure";
                          (match fn_name with Some n -> n | None -> "anon");
                          hash_concat ("params" :: params)]
         | Evaluated v -> hash_val v
         | Unevaluated | Evaluating ->
             hash_concat ["thunk"; hash_expr t.thunk_expr; hash_env t.thunk_env])
    | VNil -> hash_string "nil"
    | VBool true -> hash_string "bool:true"
    | VBool false -> hash_string "bool:false"
    | VInt n -> hash_concat ["int"; string_of_int n]
    | VFloat f -> hash_concat ["float"; string_of_float f]
    | VString s -> hash_concat ["string"; s]
    | VKeyword k -> hash_concat ["keyword"; k]
    | VSymbol s -> hash_concat ["symbol"; s]
    | VPair (car, cdr) ->
        hash_concat ["pair"; hash_val car; hash_val cdr]
    | VVector vs ->
        let parts = Array.to_list (Array.map hash_val vs) in
        hash_concat ("vector" :: parts)
    | VMap kvs ->
        let sorted = List.sort (fun (k1,_) (k2,_) ->
          String.compare (hash_val k1) (hash_val k2)
        ) kvs in
        let parts = List.map (fun (k, v) ->
          hash_concat [hash_val k; hash_val v]
        ) sorted in
        hash_concat ("map" :: parts)
    | VSet vs ->
        let sorted = List.sort String.compare (List.map hash_val vs) in
        hash_concat ("set" :: sorted)
    | VClosure { fn_name; params; body; env } ->
        let name_part = match fn_name with Some n -> n | None -> "anon" in
        hash_concat ["closure"; name_part;
                     hash_concat ("params" :: params);
                     hash_expr body]
        (* Env deliberately NOT hashed — closures hold a ref to mutable global env *)
    | VBuiltin (name, _) ->
        hash_concat ["builtin"; name]
    | VCapability cap ->
        hash_capability cap
    | VMacro { params; body; env } ->
        hash_concat ["macro"; hash_concat ("params" :: params);
                     hash_expr body]
    | VFexpr { fexpr_name; fexpr_params; fexpr_body; fexpr_env } ->
        hash_concat ["fexpr";
                     (match fexpr_name with Some n -> n | None -> "anon");
                     hash_concat ("params" :: fexpr_params);
                     hash_expr fexpr_body]
        (* Env deliberately not hashed *)
  in
  hash_val v

and hash_env (env : env) : string =
  let bindings = List.sort (fun (a,_) (b,_) -> String.compare a b) env in
  let parts = List.map (fun (name, v) ->
    hash_concat ["env_binding"; name; hash_value v]
  ) bindings in
  hash_concat ("env" :: parts)

and hash_capability (c : capability) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> "r" | Write -> "w" | ReadWrite -> "rw" in
      hash_concat ["cap_fs"; path; m]
  | CapNetwork { protocol } ->
      hash_concat ["cap_net"; protocol]
  | CapProcess -> hash_string "cap_process"
  | CapTime ms -> hash_concat ["cap_time"; string_of_int ms]
  | CapMemory bytes -> hash_concat ["cap_mem"; string_of_int bytes]
  | CapCompose caps ->
      hash_concat ("cap_compose" :: List.map hash_capability caps)
  | CapRestrict { cap; scope } ->
      hash_concat ["cap_restrict"; hash_capability cap; scope]
  | CapNone -> hash_string "cap_none"
