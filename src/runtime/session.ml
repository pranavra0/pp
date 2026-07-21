open Pp_kernel
type domain_entry = {
  dm_namespace : string list;
  dm_observe : Core_model.value;
  dm_diff : Core_model.value option;
  dm_apply : Core_model.value option;
  dm_cap : Capability.t;
  dm_observe_cell : Core_model.value option;
}
type evaluation_state = {
  thunks : (string, Core_model.thunk) Hashtbl.t;
  macros : (string, string list * Core_model.expr) Hashtbl.t;
  mutable gensym : int;
  node_thunks : (Identity_types.Node_key.t, Core_model.thunk) Hashtbl.t;
  mutable eval_depth : int;
  mutable force_depth : int;
  mutable force_path : Core_model.thunk list;
  mutable cache_bust : int;
}

type domain_state = {
  domains : (string, domain_entry) Hashtbl.t;
  probes : (string, Core_model.value) Hashtbl.t;
  preseeded_probes : (string, Core_model.value) Hashtbl.t;
}

type run_state = {
  sealed_pins : (string, string) Hashtbl.t;
  mutable observations : (string * string) list;
  run_pins : (string, string) Hashtbl.t;
  preseeded_run_pins : (string, string) Hashtbl.t;
}

type fenced_state = {
  mutable fenced_actions : (string * Core_model.value) list;
  mutable fenced_epoch_nonce : int;
  mutable fenced_epoch : string;
  mutable fenced_epoch_recovered : bool;
}

type t = {
  operations : Evaluator_ops.t;
  scheduler : Scheduler.t;
  evaluation : evaluation_state;
  domains : domain_state;
  run : run_state;
  fenced : fenced_state;
}

let create ~scheduler operations = {
  operations;
  scheduler;
  evaluation = {
    thunks = Hashtbl.create 1024; macros = Hashtbl.create 16; gensym = 0;
    node_thunks = Hashtbl.create 256; eval_depth = 0; force_depth = 0;
    force_path = [];
    cache_bust = 0;
  };
  domains = {
    domains = Hashtbl.create 16; probes = Hashtbl.create 16;
    preseeded_probes = Hashtbl.create 16;
  };
  run = {
    sealed_pins = Hashtbl.create 16; observations = [];
    run_pins = Hashtbl.create 64; preseeded_run_pins = Hashtbl.create 64;
  };
  fenced = {
    fenced_actions = []; fenced_epoch_nonce = 0; fenced_epoch = "";
    fenced_epoch_recovered = false;
  };
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
let reset_pass_state t =
  Hashtbl.clear t.domains.probes; Hashtbl.clear t.run.sealed_pins;
  Hashtbl.clear t.run.run_pins;
  Hashtbl.iter (Hashtbl.replace t.domains.probes) t.domains.preseeded_probes;
  Hashtbl.iter (Hashtbl.replace t.run.run_pins) t.run.preseeded_run_pins;
  t.run.observations <- [];
  t.fenced.fenced_actions <- []
let begin_pass t =
  reset_pass_state t;
  if not t.fenced.fenced_epoch_recovered then t.fenced.fenced_epoch <- ""
let begin_evaluation ~retain_thunks t =
  if not retain_thunks then begin
    Hashtbl.clear t.evaluation.thunks;
    Hashtbl.clear t.evaluation.node_thunks
  end;
  Hashtbl.clear t.evaluation.macros; t.evaluation.gensym <- 0;
  Hashtbl.clear t.domains.domains;
  t.evaluation.eval_depth <- 0; t.evaluation.force_depth <- 0;
  t.evaluation.force_path <- [];
  t.evaluation.cache_bust <- 0;
  reset_pass_state t;
  if t.fenced.fenced_epoch_recovered then t.fenced.fenced_epoch_recovered <- false
  else t.fenced.fenced_epoch <- ""
let begin_watch t = Hashtbl.clear t.evaluation.node_thunks
let find_thunk t = Hashtbl.find_opt t.evaluation.thunks
let add_thunk t = Hashtbl.replace t.evaluation.thunks
let find_macro t = Hashtbl.find_opt t.evaluation.macros
let set_macro t = Hashtbl.replace t.evaluation.macros
let next_gensym t =
  t.evaluation.gensym <- t.evaluation.gensym + 1;
  t.evaluation.gensym
let find_domain t = Hashtbl.find_opt t.domains.domains
let register_domain t name entry = Hashtbl.replace t.domains.domains name entry
let register_probe t name entry = Hashtbl.replace t.domains.domains name entry
let fold_domains t f init = Hashtbl.fold f t.domains.domains init
let find_probe t = Hashtbl.find_opt t.domains.probes
let set_probe t = Hashtbl.replace t.domains.probes
let preseed_probe t name value =
  Hashtbl.replace t.domains.preseeded_probes name value;
  Hashtbl.replace t.domains.probes name value
let iter_probes t f = Hashtbl.iter f t.domains.probes
let find_sealed_pin t = Hashtbl.find_opt t.run.sealed_pins
let set_sealed_pin t = Hashtbl.replace t.run.sealed_pins
let observations t = t.run.observations
let add_observation t x = t.run.observations <- x :: t.run.observations
let clear_observations t = t.run.observations <- []
let add_fenced_action t x =
  t.fenced.fenced_actions <- x :: t.fenced.fenced_actions
let take_fenced_actions t =
  let xs = List.rev t.fenced.fenced_actions in
  t.fenced.fenced_actions <- [];
  xs
let find_run_pin t = Hashtbl.find_opt t.run.run_pins
let set_run_pin t = Hashtbl.replace t.run.run_pins
let preseed_run_pin t cell hash =
  Hashtbl.replace t.run.preseeded_run_pins cell hash;
  Hashtbl.replace t.run.run_pins cell hash
let remove_run_pin t = Hashtbl.remove t.run.run_pins
let iter_run_pins t f = Hashtbl.iter f t.run.run_pins
let set_node_thunk t = Hashtbl.replace t.evaluation.node_thunks
let find_node_thunk t = Hashtbl.find_opt t.evaluation.node_thunks
let force_depth t = t.evaluation.force_depth
let set_force_depth t n = t.evaluation.force_depth <- n
let incr_force_depth t = t.evaluation.force_depth <- t.evaluation.force_depth + 1
let decr_force_depth t = t.evaluation.force_depth <- t.evaluation.force_depth - 1
let eval_depth t = t.evaluation.eval_depth
let set_eval_depth t n = t.evaluation.eval_depth <- n
let incr_eval_depth t = t.evaluation.eval_depth <- t.evaluation.eval_depth + 1
let decr_eval_depth t = t.evaluation.eval_depth <- t.evaluation.eval_depth - 1
let force_path t = t.evaluation.force_path
let set_force_path t path = t.evaluation.force_path <- path
let next_cache_bust t =
  t.evaluation.cache_bust <- t.evaluation.cache_bust + 1;
  t.evaluation.cache_bust
let fenced_epoch t = t.fenced.fenced_epoch
let start_fenced_epoch t epoch =
  t.fenced.fenced_epoch <- epoch;
  t.fenced.fenced_epoch_recovered <- false
let resume_fenced_epoch t epoch =
  t.fenced.fenced_epoch <- epoch;
  t.fenced.fenced_epoch_recovered <- true
let clear_fenced_epoch t =
  t.fenced.fenced_epoch <- "";
  t.fenced.fenced_epoch_recovered <- false
let next_fenced_epoch_nonce t =
  t.fenced.fenced_epoch_nonce <- t.fenced.fenced_epoch_nonce + 1;
  t.fenced.fenced_epoch_nonce
