exception Capability_error of string
exception Pp_exit of int
exception Reader_incomplete of string
type err_kind = Eval | Capability
exception Pp_error of {
  kind : err_kind;
  msg : string;
  pos : (string * int) option;
}
