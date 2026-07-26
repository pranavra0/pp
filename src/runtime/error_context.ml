open Pp_kernel
open Core_model
open Source_error

let with_form_location expression f =
  match expression with
  | ELocated (range, _) ->
      let pos = Some range in
      (try f () with
       | Error error -> raise (Error (with_location pos error))
       | Failure msg -> eval ?location:pos msg)
  | _ -> f ()
