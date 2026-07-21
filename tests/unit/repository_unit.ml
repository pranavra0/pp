open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let () =
  let layout = Store_layout.default in
  Store_layout.init layout;
  let objects = Object_repository.create layout in
  let key = Identity.hash_value (Core_model.VString "repository") in
  Object_repository.put objects ~key ~value:(Core_model.VInt 42);
  check (Object_repository.get objects ~key = Some (Core_model.VInt 42))
    "object repository did not return its value";
  let cache_key = Identity_types.Cache_key.of_digest key in
  let result_hash = Identity_types.Object_hash.of_digest key in
  let cell = Identity_types.Cell_id.of_string "runtime-file:p" in
  let observed = Identity_types.Observed_hash.of_digest "observed" in
  let traces = Trace_repository.create layout in
  Trace_repository.put traces ~key:cache_key ~outcome:Trace_repository.Ok
    ~result_hash ~reads:[cell, observed];
  match Trace_repository.load traces ~key:cache_key with
  | [{ Trace_repository.outcome = Trace_repository.Ok; result_hash = got; reads = [_] }] ->
      check (Identity_types.Object_hash.to_string got = key) "trace result hash changed";
      let file_pin = Remote_protocol.encode_file_pin ~cell:"file:/tmp/input" ~hash:"abc" in
      check
        (Remote_protocol.decode_pin file_pin =
         Ok (Remote_protocol.File_pin { cell = "file:/tmp/input"; hash = "abc" }))
        "file pin protocol did not round-trip";
      let probe_pin =
        match Remote_protocol.encode_probe_pin ~name:"clock" (Core_model.VInt 7) with
        | Ok pin -> pin
        | Error message -> failwith message
      in
      check
        (Remote_protocol.decode_pin probe_pin =
         Ok (Remote_protocol.Probe_pin { name = "clock"; value = Core_model.VInt 7 }))
        "probe pin protocol did not round-trip";
      let reply = Remote_protocol.Hit {
        key = "node"; result_hash = "result"; blob_hashes = ["a"; "b"];
      } in
      check
        (Remote_protocol.decode_reply (Remote_protocol.encode_reply reply) = Ok reply)
        "remote reply protocol did not round-trip";
      print_endline "repository: ok"
  | _ -> failwith "trace repository did not persist one trace"
