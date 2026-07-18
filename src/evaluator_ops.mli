type core = {
  force : Core_model.value -> Core_model.value;
  eval : Core_model.expr -> Core_model.env -> Core_model.value;
  apply : Core_model.value -> Core_model.value list -> Core_model.env -> Core_model.value;
}

type node = {
  key_of : Core_model.thunk -> string;
  run_body : key:string -> run:(unit -> Core_model.value) -> Core_model.thunk -> Core_model.value;
  resolve_hit : Core_model.thunk -> string -> bool;
}

type t = { core : core; node : node }
