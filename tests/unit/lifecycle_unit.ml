open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let scheduler =
  Scheduler.create ~policy:Scheduler.Serial
    ~remote_dispatch:(fun ~member:_ _jobs -> ())

let operations = {
  Evaluator_ops.core = {
    force = Fun.id;
    eval = (fun _ _ -> Core_model.VNil);
    apply = (fun _ _ _ -> Core_model.VNil);
  };
  node = {
    key_of = (fun _ -> Identity_types.Node_key.of_string "node");
    run_body = (fun ~key:_ ~run _ -> run ());
    resolve_hit = (fun _ _ -> false);
  };
}

let () =
  let session = Session.create ~scheduler operations in
  check (Session.next_gensym session = 1) "session gensym did not start at one";
  Session.preseed_probe session "stable" (Core_model.VInt 7);
  Session.set_probe session "transient" (Core_model.VInt 8);
  Session.add_observation session ("cell", "hash");
  Session.begin_pass session;
  check (Session.find_probe session "stable" = Some (Core_model.VInt 7))
    "preseeded probe did not survive pass reset";
  check (Session.find_probe session "transient" = None) "transient probe survived pass reset";
  check (Session.observations session = []) "observations survived pass reset";
  ignore (Session.next_gensym session);
  Session.begin_evaluation ~retain_thunks:false session;
  check (Session.next_gensym session = 1) "evaluation did not reset lifecycle counters";
  let observe = Core_model.VBuiltin ("observe", fun _ _ -> Core_model.VNil) in
  let domain_spec = Core_model.VMap [
    Core_model.VKeyword "name", Core_model.VKeyword "files";
    Core_model.VKeyword "namespace", Core_model.VVector [|Core_model.VString "file:"|];
    Core_model.VKeyword "observe", observe;
    Core_model.VKeyword "write-cap", Core_model.VCapability Capability.none;
  ] in
  (match Domain_config.decode_domain ~force:Fun.id domain_spec with
   | Ok { Domain_config.name = "files";
          entry = { Session.dm_namespace = ["file:"]; _ } } -> ()
   | _ -> failwith "domain configuration did not decode to a typed registration");
  (match Domain_config.decode_domain ~force:Fun.id Core_model.VNil with
   | Error _ -> ()
   | Ok _ -> failwith "invalid domain configuration was accepted");
  (match Process.exec [] with
   | _ -> failwith "empty process argv was accepted"
   | exception Invalid_argument _ -> ());
  print_endline "lifecycle: ok"
