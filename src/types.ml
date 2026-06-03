(* pp types — mutually recursive type definitions for the pp runtime *)

(* Environment: a list of (name, value) bindings *)
type env = (string * value) list

(* Expressions — the AST produced by the reader *)
and expr =
  | ELiteral of value       (* self-evaluating literal *)
  | ESymbol of string       (* variable reference *)
  | EIf of expr * expr * expr  (* conditional *)
  | ELet of (string * expr) list * expr  (* parallel let bindings (lazy) *)
  | EFn of string list * expr  (* anonymous function *)
  | EApply of expr * expr list  (* function application *)
  | EQuote of expr          (* quotation: 'x *)
  | EForce of expr          (* explicit force *)
  | EEffect of expr * expr  (* (effect caps-expr body) — effectful block *)
  | EPerform of string * expr list  (* (perform effect-name args...) *)
  | EWithHandler of (string * expr) list * expr  (* effect handler installation *)
  | EDelay of expr          (* explicit delay *)
  | EDo of expr list        (* sequencing — forces each, returns last *)
  | EDef of string * string list * expr  (* (def name (params...) body) *)
  | EDefFexpr of string * string list * expr  (* (def-fexpr name (params...) body) *)
  | ELetStar of (string * expr) list * expr  (* sequential let — desugared by reader *)

(* Values — the runtime representation *)
and value =
  | VNil
  | VBool of bool
  | VInt of int
  | VFloat of float
  | VString of string
  | VKeyword of string
  | VSymbol of string
  | VPair of value * value
  | VVector of value array
  | VMap of (value * value) list  (* association list for simplicity *)
  | VSet of value list
  | VClosure of closure
  | VBuiltin of string * (value list -> value)  (* name + ocaml function *)
  | VCapability of capability
  | VThunk of thunk
  | VMacro of closure
  | VFexpr of fexpr

(* Function closure *)
and closure = {
  fn_name : string option;  (* optional name for debugging *)
  params : string list;
  body : expr;
  env : env ref;  (* reference to environment — sees later defs *)
}

(* Fexpr — operative: receives unevaluated args + calling environment *)
and fexpr = {
  fexpr_name : string option;
  fexpr_params : string list;
  fexpr_body : expr;
  fexpr_env : env ref;  (* reference to environment *)
}

(* Thunk — a suspended computation *)
and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;
  thunk_expr : expr;
  thunk_env : env;
}

and thunk_status =
  | Unevaluated
  | Evaluating
  | Evaluated of value

(* Capabilities — authority tokens *)
and capability =
  | CapFilesystem of { path : string; mode : fs_mode }
  | CapNetwork of { protocol : string }
  | CapProcess
  | CapTime of int       (* CPU time budget in ms *)
  | CapMemory of int     (* memory budget in bytes *)
  | CapCompose of capability list
  | CapRestrict of { cap : capability; scope : string }
  | CapNone

and fs_mode = Read | Write | ReadWrite

(* Helper: make a closure — takes an env ref directly *)
let make_closure ?(name=None) params body env_ref =
  VClosure { fn_name = name; params; body; env = env_ref }

(* Helper: make a fexpr *)
let make_fexpr ?(name=None) params body env_ref =
  VFexpr { fexpr_name = name; fexpr_params = params; fexpr_body = body; fexpr_env = env_ref }

(* Helper: make a thunk *)
let make_thunk expr env =
  VThunk { thunk_status = Unevaluated; thunk_hash = None; thunk_expr = expr; thunk_env = env }

(* Helper: look up a binding in the environment *)
let rec lookup_env (env : env) (name : string) : value option =
  match env with
  | [] -> None
  | (n, v) :: rest -> if n = name then Some v else lookup_env rest name

(* Helper: extend environment with a single binding *)
let extend_env (env : env) (name : string) (v : value) : env =
  (name, v) :: env

(* Helper: extend environment with multiple bindings *)
let extend_env_many (env : env) (bindings : (string * value) list) : env =
  List.fold_left (fun e (n, v) -> extend_env e n v) env bindings

(* Pretty-print a value for the REPL *)
let rec string_of_value (v : value) : string =
  match v with
  | VNil -> "nil"
  | VBool true -> "true"
  | VBool false -> "false"
  | VInt n -> string_of_int n
  | VFloat f -> string_of_float f
  | VString s -> "\"" ^ String.escaped s ^ "\""
  | VKeyword k -> ":" ^ k
  | VSymbol s -> s
  | VPair (car, cdr) ->
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
  | VCapability c -> string_of_capability c
  | VThunk t ->
      (match t.thunk_status with
       | Unevaluated -> "#<thunk>"
       | Evaluating -> "#<thunk: evaluating>"
       | Evaluated v -> "#<thunk: " ^ string_of_value v ^ ">")
  | VMacro _ -> "#<macro>"
  | VFexpr { fexpr_name = Some n; _ } -> "#<fexpr " ^ n ^ ">"
  | VFexpr { fexpr_name = None; _ } -> "#<fexpr>"

and string_of_capability (c : capability) : string =
  match c with
  | CapFilesystem { path; mode } ->
      let m = match mode with Read -> ":ro" | Write -> ":wo" | ReadWrite -> ":rw" in
      "#<cap fs " ^ path ^ " " ^ m ^ ">"
  | CapNetwork { protocol } -> "#<cap net " ^ protocol ^ ">"
  | CapProcess -> "#<cap process>"
  | CapTime ms -> "#<cap time " ^ string_of_int ms ^ "ms>"
  | CapMemory bytes -> "#<cap memory " ^ string_of_int bytes ^ ">"
  | CapCompose caps -> "#<cap compose " ^ string_of_int (List.length caps) ^ ">"
  | CapRestrict { scope; _ } -> "#<cap restrict " ^ scope ^ ">"
  | CapNone -> "#<cap none>"
