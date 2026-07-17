(* pp types — mutually recursive type definitions for the pp runtime.

   This is the foundation of the codebase: every module depends on these
   types. The .mli freezes the surface that the type, identity, and extent
   work left behind, trimmed to what callers actually use. *)

exception Capability_error of string
exception Pp_exit of int
exception Reader_incomplete of string
(* A runtime or parse error carrying its source location as structured data;
   [pos = None] means not yet located ([Runtime.with_form_location] attaches it
   at the innermost form). [kind] records whether it may be memoized as a
   failing node trace: [Eval] may (LAW 28), [Capability] may not (LAW 15). *)
type err_kind = Eval | Capability
exception Pp_error of { kind : err_kind; msg : string; pos : (string * int) option }

(* ---- Environment ---- *)

type env = {
  env_id : int;
  env_hash : string;
  bindings : (string * value) list;
}

(* ---- Patterns for match expressions ---- *)

and pattern =
  | PLiteral of value
  | PVariable of string
  | PWildcard
  | PList of pattern list * pattern option
  | PTagged of string * pattern list

(* ---- Expressions — the AST produced by the reader ---- *)

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
  | VMap of (value * value) list
  | VSet of value list
  | VClosure of closure
  | VBuiltin of string * (value list -> value)
  | VCapability of Capability.t
  | VThunk of thunk
  | VEnvMap of (string * value) list
  | VBytecode of bytecode
  | VSealed of string

(* ---- Function closure ---- *)

and closure = {
  fn_name : string option;
  params : string list;
  body : expr;
  env : env ref;
  vm_bc : bytecode;
  vm_offset : int;
  vm_frames : frame list;
}

(* ---- Thunk (suspended computation) ---- *)

and thunk = {
  mutable thunk_status : thunk_status;
  mutable thunk_hash : string option;
  thunk_expr : expr;
  mutable thunk_env : env;
  vm_code : (bytecode * int * frame list) option;
  type_ann : expr option;
  thunk_loc : (string * int) option;
  config_hash : string;
  mutable thunk_persist : bool;
  mutable node_fv : (string * int * int) list;
  mutable node_caps : Capability.t list;
}

and thunk_status = Unevaluated | Evaluating | Evaluated of value

(* ---- Bytecode VM types ---- *)

and opcode =
  | PUSH of int
  | LOAD_LOCAL of int * int
  | STORE_LOCAL of int
  | LOAD_GLOBAL of int
  | STORE_GLOBAL of int
  | POP
  | DUP
  | JUMP of int
  | JUMP_IF_FALSE of int
  | FORCE
  | MAKE_THUNK of int * expr option * (string * int) option
  | MAKE_NODE of int * expr * (string * int * int) list * expr option *
      (string * int) option
  | MAKE_CLOSURE of int * int
  | CALL of int
  | TAIL_CALL of int
  | RETURN
  | HALT
  | WITH_CAPS of int
  | PERFORM of int * int
  | WITH_HANDLER of int * int
  | WITH_CONFIG of int
  | MAKE_MODULE of int
  | IMPORT
  | LOAD_FILE of int
  | LOAD_MODULE_FILE of int
  | ISLAND of int * int option
  | READ_CONFIG
  | UNBOUND of int

and bytecode = {
  consts : value array;
  code : opcode array;
  nparams_of : (int, int) Hashtbl.t;
  param_names_of : (int, string list) Hashtbl.t;
  closure_names_of : (int, string) Hashtbl.t;
}

and frame = { mutable slots : value array; mutable len : int; }

(* ---- Compiler types ---- *)

type cenv = string list list

type def_info = { name : string; slot : int; }

type comp_state = {
  mutable ops : opcode list;
  mutable ops_len : int;
  mutable const_ht : (string, int) Hashtbl.t;
  mutable consts : value list;
  mutable consts_len : int;
  mutable nparams_of : (int, int) Hashtbl.t;
  mutable param_names_of : (int, string list) Hashtbl.t;
  mutable closure_names_of : (int, string) Hashtbl.t;
  mutable cenv : cenv;
  mutable in_module : bool;
}

val fresh_comp_state : unit -> comp_state

(* ---- Environment constructors ---- *)

val empty_env : env
val extend_env : env -> string -> value -> env
val env_of_bindings : (string * value) list -> env
val lookup_env : env -> string -> value option

(* ---- Content-addressing hashing ---- *)

val hex_encode : string -> string
val hash_string : string -> string
val hash_concat : string list -> string
val canonical_float_string : float -> string
val dummy_bytecode : bytecode
val hash_expr : expr -> string
val hash_pattern : pattern -> string
val hash_value : value -> string

(* ---- Node-boundary authority ban ---- *)

val contains_authority : value -> bool
val contains_sealed : value -> bool

(* ---- Free-variable analysis ---- *)

module SS : sig
  type t = Set.Make(String).t
  val elements : t -> string list
  val for_all : (string -> bool) -> t -> bool
end
val free_vars : expr -> SS.t

(* ---- Constructor helpers ---- *)

val make_closure :
  ?name:string option -> string list -> expr -> env ref -> value

val make_thunk :
  ?vm_code:(bytecode * int * frame list) option ->
  ?type_ann:expr option ->
  ?thunk_loc:(string * int) option ->
  ?config_hash:string -> expr -> env -> value

val make_frame : int -> frame
val frame_get : frame -> int -> value
val frame_set : frame -> int -> value -> unit

(* ---- Quotation: expr -> value ---- *)

val quote_to_value : expr -> value

(* ---- Pretty-print ---- *)

val string_of_value : value -> string

(* ---- String extraction ---- *)

val string_like : value -> string option

(* ---- Unquotation: value -> expr ---- *)

val value_to_expr : value -> expr

(* ---- Pattern matching ---- *)

val match_pattern : value -> pattern -> (string * value) list option
