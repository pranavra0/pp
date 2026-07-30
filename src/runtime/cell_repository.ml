open Pp_kernel
open Source_error
let read_raw path = match Store_layout.read path with
  | Some content -> content
  | None ->
      raise (Error (Store (Read_failed { path; message = "file is missing or unreadable" })))
let unpin_file path =
  Session.remove_run_pin (Effect.perform Dynamic_scope.Get_session)
    (Cell.serialize (Observation.file path))
let read_file = Observation.read_file_cell
let read_sealed = Observation.read_sealed_cell
