type domain_entry = {
  dm_namespace : string list;
  dm_observe : Types.value;
  dm_diff : Types.value option;
  dm_apply : Types.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Types.value option;
}
type t = {
  thunks : (string, Types.thunk) Hashtbl.t;
  macros : (string, string list * Types.expr) Hashtbl.t;
  mutable gensym : int;
  domains : (string, domain_entry) Hashtbl.t;
  probes : (string, Types.value) Hashtbl.t;
  sealed_pins : (string, string) Hashtbl.t;
  mutable observations : (string * string) list;
  mutable fenced_actions : (string * Types.value) list;
  run_pins : (string, string) Hashtbl.t;
  node_thunks : (string, Types.thunk) Hashtbl.t;
  mutable probe_observer : string -> string option;
  mutable domain_observer : string -> string -> string option;
  mutable current_env : Types.env;
  mutable force_depth : int;
  mutable cache_bust : int;
  mutable fenced_epoch : string;
}

let create () = {
  thunks = Hashtbl.create 1024; macros = Hashtbl.create 16; gensym = 0;
  domains = Hashtbl.create 16; probes = Hashtbl.create 16;
  sealed_pins = Hashtbl.create 16; observations = [];
  fenced_actions = [];
  run_pins = Hashtbl.create 64; node_thunks = Hashtbl.create 256;
  probe_observer = (fun _ -> None); domain_observer = (fun _ _ -> None);
  current_env = Types.empty_env; force_depth = 0; cache_bust = 0; fenced_epoch = "";
}
let begin_pass t =
  Hashtbl.clear t.probes; Hashtbl.clear t.sealed_pins;
  Hashtbl.clear t.run_pins; t.observations <- []
let begin_evaluation ~retain_thunks t =
  if not retain_thunks then begin Hashtbl.clear t.thunks; Hashtbl.clear t.node_thunks end;
  Hashtbl.clear t.macros; t.gensym <- 0; Hashtbl.clear t.domains;
  t.current_env <- Types.empty_env; t.force_depth <- 0; t.cache_bust <- 0;
  t.fenced_actions <- []; begin_pass t
let begin_watch t = Hashtbl.clear t.node_thunks
let find_thunk t = Hashtbl.find_opt t.thunks
let add_thunk t = Hashtbl.replace t.thunks
let find_macro t = Hashtbl.find_opt t.macros
let set_macro t = Hashtbl.replace t.macros
let next_gensym t = t.gensym <- t.gensym + 1; t.gensym
let find_domain t = Hashtbl.find_opt t.domains
let set_domain t = Hashtbl.replace t.domains
let fold_domains t f init = Hashtbl.fold f t.domains init
let find_probe t = Hashtbl.find_opt t.probes
let set_probe t = Hashtbl.replace t.probes
let iter_probes t f = Hashtbl.iter f t.probes
let find_sealed_pin t = Hashtbl.find_opt t.sealed_pins
let set_sealed_pin t = Hashtbl.replace t.sealed_pins
let observations t = t.observations
let add_observation t x = t.observations <- x :: t.observations
let clear_observations t = t.observations <- []
let add_fenced_action t x = t.fenced_actions <- x :: t.fenced_actions
let take_fenced_actions t = let xs = List.rev t.fenced_actions in t.fenced_actions <- []; xs
let find_run_pin t = Hashtbl.find_opt t.run_pins
let set_run_pin t = Hashtbl.replace t.run_pins
let remove_run_pin t = Hashtbl.remove t.run_pins
let iter_run_pins t f = Hashtbl.iter f t.run_pins
let set_node_thunk t = Hashtbl.replace t.node_thunks
let find_node_thunk t = Hashtbl.find_opt t.node_thunks
let set_probe_observer t f = t.probe_observer <- f
let observe_probe t = t.probe_observer
let set_domain_observer t f = t.domain_observer <- f
let observe_domain t = t.domain_observer
let current_env t = t.current_env
let set_current_env t env = t.current_env <- env
let force_depth t = t.force_depth
let set_force_depth t n = t.force_depth <- n
let incr_force_depth t = t.force_depth <- t.force_depth + 1
let decr_force_depth t = t.force_depth <- t.force_depth - 1
let next_cache_bust t = t.cache_bust <- t.cache_bust + 1; t.cache_bust
let fenced_epoch t = t.fenced_epoch
let set_fenced_epoch t epoch = t.fenced_epoch <- epoch
