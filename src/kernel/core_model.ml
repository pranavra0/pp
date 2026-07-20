type env = {
  env_id : int;
  env_hash : string;
  bindings : (string * value) list;
}


(* ---- Patterns for match expressions ---- *)
and pattern =
  | PLiteral of value       (* 42, "hello", true, nil *)
  | PVariable of string     (* x — matches anything, binds *)
  | PWildcard               (* _ — matches anything, no bind *)
  | PList of pattern list * pattern option  (* [a, b, ...rest] *)
  | PTagged of string * pattern list  (* [:ok, v] or [:err, e] *)

(* ---- Expressions — the AST produced by the reader ---- *)

and expr =
  | ELiteral of value       (* self-evaluating literal *)
  | ESymbol of string       (* variable reference *)
  | EIf of expr * expr * expr  (* conditional *)
  | ELet of (string * expr) list * expr  (* parallel let bindings (lazy) *)
  | EFn of string list * expr  (* anonymous function *)
  | EApply of expr * expr list  (* function application *)
  | EQuote of expr          (* quotation: 'x *)
  | EForce of expr          (* explicit force *)
  | EWithCaps of expr * expr  (* (with-caps cap-expr body) — replace the
                                 ambient capability set for body's extent *)
  | EPerform of string * expr list  (* (perform effect-name args...) *)
  | EWithHandler of (string * expr) list * expr  (* effect handler installation *)
  | EDelay of expr          (* explicit delay *)
  | ENode of expr           (* (node body) — persistent cacheable node *)
  | EDefNode of string * string list * expr  (* (defnode (name params...) body...) *)
  | EDo of expr list        (* sequencing — forces each, returns last *)
  | EDef of string * string list * expr  (* (def (name params...) body) *)
  | EDefValue of string * expr  (* eager value binding *)
  | ELetStar of (string * expr) list * expr  (* sequential let — desugared by reader *)
  | EModule of expr list        (* (module body...) — thunk producing an env *)
  | EImport of expr             (* (import mod-expr) — force module, merge env *)
  | ELoad of string             (* (load "file.pp") — eval file in current env *)
  | ELoadModule of string       (* (load-module "file.pp") — eval file as module *)
  | EIsland of string * string option  (* (island <uri> [version]) — remote import *)
  | EWithConfig of expr * expr     (* (with-config {map} body) — ambient config *)
  | EConfig of expr * expr option  (* (config key [default]) — read config *)
  | ETyped of expr * expr          (* (the-expr : type) — type annotation *)
  | ELocated of (string * int) * expr  (* source-located expression *)
  | EMatch of expr * (pattern * expr option * expr) list
      (* pattern, optional guard, body *)

(* ---- Values — the runtime representation ---- *)

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
  | VBuiltin of string * (value list -> env -> value)  (* name + implementation *)
  | VCapability of Capability.t
  | VThunk of thunk
  | VEnvMap of (string * value) list  (* module export: list of (name, thunk) pairs *)
  | VSealed of string  (* confidential bytes; presentation and codecs redact them *)

(* ---- Function closure ---- *)
and closure = {
  fn_name : string option;  (* optional name for debugging *)
  params : string list;
  body : expr;
  env : env ref;            (* captured environment *)
}

and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;  (* precomputed content-addressable hash *)
  thunk_expr : expr;
  mutable thunk_env : env;
  thunk_name : string option;          (* binding name, for force-cycle errors *)
  type_ann : expr option;              (* lazy gradual type annotation *)
  thunk_loc : (string * int) option;   (* source location for error reporting *)
  config_hash : string;                (* ReaderT config snapshot identity *)
  mutable thunk_persist : bool;         (* persist across runs? true for node, false for delay/let *)
  mutable node_caps : Capability.t list; (* capabilities captured by a persistent node *)
}
and thunk_status =
  | Unevaluated
  | Evaluating
  | Evaluated of value
