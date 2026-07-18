open Core_model

let rec string_of_value (v : value) : string =
  match v with
  | VNil -> "nil"
  | VBool true -> "true"
  | VBool false -> "false"
  | VInt n -> string_of_int n
  | VFloat f -> if f <> f then "nan" else string_of_float f
  | VString s -> "\"" ^ String.escaped s ^ "\""
  | VKeyword k -> ":" ^ k
  | VSymbol s -> s
  | VPair _ ->
      let rec list_string v =
        match v with
        | VPair (a, VNil) -> string_of_value a
        | VPair (a, d) -> string_of_value a ^ " " ^ list_string d
        | _ -> ". " ^ string_of_value v
      in
      "(" ^ list_string v ^ ")"
  | VVector vs ->
      "[" ^ String.concat " " (List.map string_of_value (Array.to_list vs)) ^ "]"
  | VMap kvs ->
      "{" ^ String.concat ", "
        (List.map (fun (k, v) -> string_of_value k ^ " " ^ string_of_value v) kvs) ^ "}"
  | VSet vs ->
      "#{" ^ String.concat " " (List.map string_of_value vs) ^ "}"
  | VClosure { fn_name = Some n; _ } -> "#<fn " ^ n ^ ">"
  | VClosure { fn_name = None; _ } -> "#<fn>"
  | VBuiltin (name, _) -> "#<builtin " ^ name ^ ">"
  | VCapability c -> Capability.to_string c
  | VThunk t ->
      (match t.thunk_status with
       | Unevaluated -> "#<thunk>"
       | Evaluating -> "#<thunk: evaluating>"
       | Evaluated v -> "#<thunk: " ^ string_of_value v ^ ">")
  | VEnvMap bindings ->
      "#<envmap " ^ string_of_int (List.length bindings) ^ " exports>"
  | VSealed _ ->
      (* Never print the bytes. A leak would defeat the
         whole feature. Every printer (REPL, `print`, debug) goes through
         this one function, so redaction is total by construction. *)
      "#<sealed>"

let rec value_list_opt (v : value) : value list option =
  match v with
  | VNil -> Some []
  | VPair (a, d) ->
      (match value_list_opt d with
       | Some rest -> Some (a :: rest)
       | None -> None)
  | _ -> None

let string_like (v : value) : string option =
  match v with
  | VString s | VKeyword s | VSymbol s -> Some s
  | _ -> None
