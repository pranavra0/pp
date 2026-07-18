open Pp_kernel
let read_raw path = match Store_layout.read path with
  | Some content -> content | None -> raise (Sys_error path)
let unpin_file path =
  Session.remove_run_pin (Effect.perform Dynamic_scope.Get_session)
    (Cell.serialize (Observation.file path))
let read_file path =
  let cell = Cell.serialize (Observation.file path) in
  let serve content hash = Observation.record (Cell.parse cell) hash; content in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_run_pin session cell with
  | Some hash ->
      (match Blob_repository.get Blob_repository.default hash with
       | Some content -> serve content hash
       | None ->
           let content = read_raw path in
           let hash = Blob_repository.put Blob_repository.default content in
           Session.set_run_pin session cell hash; serve content hash)
  | None ->
      let content = read_raw path in
      let hash = Blob_repository.put Blob_repository.default content in
      Session.set_run_pin session cell hash; serve content hash
let read_sealed path =
  let cell = Cell.serialize (Observation.sealed path) in
  let session = Effect.perform Dynamic_scope.Get_session in
  match Session.find_sealed_pin session cell with
  | Some bytes -> Observation.record (Cell.parse cell) (Hasher.hash_string bytes); bytes
  | None ->
      let bytes = read_raw path in
      Session.set_sealed_pin session cell bytes;
      Observation.record (Cell.parse cell) (Hasher.hash_string bytes); bytes
