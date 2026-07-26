open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let scheduler = Scheduler.create ~handler:Scheduler.serial

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
  check (Session.executor session = None)
    "session installed an ambient executor";
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
  let request = {
    Executor.tool = [];
    tool_path = "tool";
    arguments = [];
    inputs = [];
    environment = [];
    platform = ["os", "linux"];
    policy = Core_model.VMap [];
    outputs = ["a"; "b"];
  } in
  let result outputs evidence resources = {
    Executor.exit_status = 0;
    stdout = "";
    stderr = "";
    outputs;
    evidence;
    resources;
  } in
  let normalized =
    Executor.run
      (Executor.make ~classify:(fun _ -> Executor.Cacheable)
         ~execute:(fun _ -> result [] ["z", "2"; "a", "1"] []))
      request
  in
  check (normalized.Executor.evidence = ["a", "1"; "z", "2"])
    "executor evidence was not canonicalized";
  (match Executor.run
           (Executor.make ~classify:(fun _ -> Executor.Cacheable)
              ~execute:(fun _ -> result [] ["", "bad"] []))
           request with
   | _ -> failwith "executor accepted empty evidence name"
   | exception Failure _ -> ());
  (match Executor.run
           (Executor.make ~classify:(fun _ -> Executor.Cacheable)
              ~execute:(fun _ -> result [] ["same", "1"; "same", "2"] []))
           request with
   | _ -> failwith "executor returned duplicate evidence"
   | exception Failure _ -> ());
  let invalid_tree = [
    Artifact_tree.Directory { path = "out"; mode = 0o755 };
    Artifact_tree.File {
      path = "out";
      mode = 0o644;
      blob = Hasher.hash_string "output";
    };
  ] in
  (match Executor.run
           (Executor.make ~classify:(fun _ -> Executor.Cacheable)
              ~execute:(fun _ -> result invalid_tree [] []))
           request with
   | _ -> failwith "executor accepted an invalid output tree"
   | exception Failure _ -> ());
  let closed_request = Core_model.VMap [
    Core_model.VKeyword "tool",
      Artifact_tree.to_value [];
    Core_model.VKeyword "tool-path", Core_model.VString "tool";
    Core_model.VKeyword "args", Core_model.VNil;
    Core_model.VKeyword "inputs",
      Artifact_tree.to_value [];
    Core_model.VKeyword "env", Core_model.VMap [];
    Core_model.VKeyword "platform",
      Core_model.VMap [Core_model.VString "test", Core_model.VString "true"];
    Core_model.VKeyword "policy",
      Core_model.VMap [Core_model.VKeyword "redundancy", Core_model.VInt 3];
    Core_model.VKeyword "outputs", Core_model.VNil;
  ] in
  let process_cap = Capability.mint ~realpath:Fun.id "process" in
  let run_in_node executor =
    let session = Session.create ~executor ~scheduler operations in
    try Closed_action.run [closed_request] with
    | effect Dynamic_scope.Get_session, k -> Effect.Deep.continue k session
    | effect Dynamic_scope.Get_capabilities, k ->
        Effect.Deep.continue k [process_cap]
    | effect Dynamic_scope.In_node, k -> Effect.Deep.continue k true
  in
  let executions = ref 0 in
  let classified_policy = ref Core_model.VNil in
  let cacheable =
    Executor.make
      ~classify:(fun request ->
        classified_policy := request.Executor.policy;
        Executor.Cacheable)
      ~execute:(fun _ -> incr executions; result [] [] [])
  in
  ignore (run_in_node cacheable);
  check (!executions = 1) "cacheable executor did not run inside a node";
  check (!classified_policy =
    Core_model.VMap [Core_model.VKeyword "redundancy", Core_model.VInt 3])
    "executor did not receive ordinary request policy";
  let scripting =
    Executor.make
      ~classify:(fun _ -> Executor.Scripting_only "test ambient input")
      ~execute:(fun _ -> incr executions; result [] [] [])
  in
  (match run_in_node scripting with
   | _ -> failwith "scripting-only executor ran inside a node"
   | exception Failure message ->
       check (String.starts_with
         ~prefix:"run-closed!: executor classifies this request as scripting-only"
         message)
         "scripting-only executor reported the wrong boundary error");
  check (!executions = 1)
    "scripting-only executor performed work before refusing";
  print_endline "lifecycle: ok"
