open Pp_kernel
open Pp_runtime

let check condition message = if not condition then failwith message

let () =
  let ids = [Cell.File "p"; Cell.Env "HOME"; Cell.Argv; Cell.Domain {name="d"; sub="x"}] in
  List.iter (fun cell ->
    let text = Cell.serialize cell in
    check (Cell.serialize (Cell.parse text) = text) "cell identity did not round-trip") ids;
  check (Observation.authorized [] (Cell.RuntimeFile "missing"))
    "runtime-file observation should be authority-independent";
  check (not (Observation.authorized [] (Cell.File "/missing")))
    "file observation bypassed capability gating";
  check (not (Observation.authorized [] (Cell.Unknown "future")))
    "unknown observation was authorized";
  check (Observation.env_hash None <> Observation.env_hash (Some ""))
    "environment absence was not distinguished from empty value";
  print_endline "observation: ok"
