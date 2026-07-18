type core = {
  force : Types.value -> Types.value;
  eval : Types.expr -> Types.env -> Types.value;
  apply : Types.value -> Types.value list -> Types.env -> Types.value;
}

type node = {
  key_of : Types.thunk -> string;
  run_body : key:string -> run:(unit -> Types.value) -> Types.thunk -> Types.value;
  resolve_hit : Types.thunk -> string -> bool;
}

type t = { core : core; node : node }
