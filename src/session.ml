type domain_entry = {
  dm_namespace : string list;
  dm_observe : Core_model.value;
  dm_diff : Core_model.value option;
  dm_apply : Core_model.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Core_model.value option;
}
type t = {
  operations : Evaluator_ops.t;
  scheduler : Scheduler.t;
  thunks : (string, Core_model.thunk) Hashtbl.t;
  macros : (string, string list * Core_model.expr) Hashtbl.t;
  mutable gensym : int;
  domains : (string, domain_entry) Hashtbl.t;
  probes : (string, Core_model.value) Hashtbl.t;
  preseeded_probes : (string, Core_model.value) Hashtbl.t;
  sealed_pins : (string, string) Hashtbl.t;
  mutable observations : (string * string) list;
  mutable fenced_actions : (string * Core_model.value) list;
  run_pins : (string, string) Hashtbl.t;
  preseeded_run_pins : (string, string) Hashtbl.t;
  node_thunks : (Identity_types.Node_key.t, Core_model.thunk) Hashtbl.t;
  mutable force_depth : int;
  mutable cache_bust : int;
  mutable fenced_epoch : string;
}

let create ~scheduler operations = {
  operations;
  scheduler;
  thunks = Hashtbl.create 1024; macros = Hashtbl.create 16; gensym = 0;
  domains = Hashtbl.create 16; probes = Hashtbl.create 16;
  preseeded_probes = Hashtbl.create 16;
  sealed_pins = Hashtbl.create 16; observations = [];
  fenced_actions = [];
  run_pins = Hashtbl.create 64; preseeded_run_pins = Hashtbl.create 64;
  node_thunks = Hashtbl.create 256;
  force_depth = 0; cache_bust = 0; fenced_epoch = "";
}
let force t = t.operations.core.force
let core_operations t = t.operations.core
let node_operations t = t.operations.node
let scheduler t = t.scheduler
let call t ~env fn args =
  match fn with
  | Core_model.VClosure c ->
      if List.length c.params <> List.length args then
        failwith (Printf.sprintf
          "domain function expects %d argument(s), got %d"
          (List.length c.params) (List.length args));
      t.operations.core.apply fn args env
  | Core_model.VBuiltin _ -> t.operations.core.apply fn args env
  | _ -> failwith "domain function value is not a function"
let begin_pass t =
  Hashtbl.clear t.probes; Hashtbl.clear t.sealed_pins;
  Hashtbl.clear t.run_pins;
  Hashtbl.iter (Hashtbl.replace t.probes) t.preseeded_probes;
  Hashtbl.iter (Hashtbl.replace t.run_pins) t.preseeded_run_pins;
  t.observations <- []
let begin_evaluation ~retain_thunks t =
  if not retain_thunks then begin Hashtbl.clear t.thunks; Hashtbl.clear t.node_thunks end;
  Hashtbl.clear t.macros; t.gensym <- 0; Hashtbl.clear t.domains;
  t.force_depth <- 0; t.cache_bust <- 0;
  t.fenced_actions <- []; begin_pass t
let begin_watch t = Hashtbl.clear t.node_thunks
let find_thunk t = Hashtbl.find_opt t.thunks
let add_thunk t = Hashtbl.replace t.thunks
let find_macro t = Hashtbl.find_opt t.macros
let set_macro t = Hashtbl.replace t.macros
let next_gensym t = t.gensym <- t.gensym + 1; t.gensym
let find_domain t = Hashtbl.find_opt t.domains
let register_domain t name entry = Hashtbl.replace t.domains name entry
let register_probe t name entry = Hashtbl.replace t.domains name entry
let fold_domains t f init = Hashtbl.fold f t.domains init
let find_probe t = Hashtbl.find_opt t.probes
let set_probe t = Hashtbl.replace t.probes
let preseed_probe t name value =
  Hashtbl.replace t.preseeded_probes name value;
  Hashtbl.replace t.probes name value
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
let preseed_run_pin t cell hash =
  Hashtbl.replace t.preseeded_run_pins cell hash;
  Hashtbl.replace t.run_pins cell hash
let remove_run_pin t = Hashtbl.remove t.run_pins
let iter_run_pins t f = Hashtbl.iter f t.run_pins
let set_node_thunk t = Hashtbl.replace t.node_thunks
let find_node_thunk t = Hashtbl.find_opt t.node_thunks
let force_depth t = t.force_depth
let set_force_depth t n = t.force_depth <- n
let incr_force_depth t = t.force_depth <- t.force_depth + 1
let decr_force_depth t = t.force_depth <- t.force_depth - 1
let next_cache_bust t = t.cache_bust <- t.cache_bust + 1; t.cache_bust
let fenced_epoch t = t.fenced_epoch
let set_fenced_epoch t epoch = t.fenced_epoch <- epoch
