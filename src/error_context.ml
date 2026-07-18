open Types

let with_form_location expression f =
  match expression with
  | ELocated ((file, line), _) ->
      let pos = Some (file, line) in
      (try f () with
       | Pp_error { pos = Some _; _ } as error -> raise error
       | Pp_error error -> raise (Pp_error { error with pos })
       | Failure msg -> raise (Pp_error { kind = Eval; msg; pos })
       | Capability_error msg ->
           raise (Pp_error { kind = Capability; msg; pos }))
  | _ -> f ()
