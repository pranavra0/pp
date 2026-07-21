type closure_kind = Function | Node

type env = {
  env_id : int;
  env_hash : string;
  bindings : (string * value) list;
}

and pattern =
  | PLiteral of value
  | PVariable of string
  | PWildcard
  | PList of pattern list * pattern option
  | PTagged of string * pattern list

and expr =
  | ELiteral of value
  | ESymbol of string
  | EIf of expr * expr * expr
  | ELet of (string * expr) list * expr
  | EFn of string list * expr
  | EApply of expr * expr list
  | EQuote of expr
  | EForce of expr
  | EWithCaps of expr * expr
  | EPerform of string * expr list
  | EWithHandler of (string * expr) list * expr
  | EDelay of expr
  | ENode of expr
  | EDefNode of string * string list * expr
  | EDo of expr list
  | EDef of string * string list * expr
  | EDefValue of string * expr
  | ELetStar of (string * expr) list * expr
  | EModule of expr list
  | EImport of expr
  | ELoad of string
  | ELoadModule of string
  | EIsland of string * string option
  | EWithConfig of expr * expr
  | EConfig of expr * expr option
  | ETyped of expr * expr
  | ELocated of (string * int) * expr
  | EMatch of expr * (pattern * expr option * expr) list

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
  | VMap of (value * value) list
  | VSet of value list
  | VClosure of closure
  | VBuiltin of string * (value list -> env -> value)
  | VCapability of Capability.t
  | VThunk of thunk
  | VEnvMap of (string * value) list
  | VSealed of string

and thunk_kind =
  | Ephemeral
  | Persistent of {
      captured_caps : Capability.t list;
      argument_values : value list;
    }

and closure = {
  fn_name : string option;
  params : string list;
  body : expr;
  env : env ref;
  closure_kind : closure_kind;
}

and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;
  thunk_expr : expr;
  mutable thunk_env : env;
  thunk_name : string option;
  type_ann : expr option;
  thunk_loc : (string * int) option;
  config_hash : string;
  thunk_kind : thunk_kind;
}

and thunk_status = Unevaluated | Evaluating | Evaluated of value
