open Pp_kernel
type t = {
  session : Session.t;
  invocation : Invocation.t;
}

let create ~session ~invocation = { session; invocation }
let session t = t.session
let invocation t = t.invocation

let should_run t =
  Invocation.program_reconcile_root t.invocation <> None
  || Invocation.program_supervise t.invocation
  || Domains.any_write_domain_registered ()

let recover t ~decide = Fenced.recover_unknown ~decide

let run t desired =
  let sink = Session.event_sink t.session in
  let parent_event_id = Event_sink.emit sink (Event.Runtime_boundary {
    boundary = Event.Reconcile_start; subject = "pass"; count = 1;
  }) in
  let pass = Domains.prepare_pass t.invocation desired in
  Domains.run_pass pass;
  Fenced.drain ();
  ignore (Event_sink.emit sink ?parent_event_id (Event.Runtime_boundary {
    boundary = Event.Reconcile_finish; subject = "pass"; count = 1;
  }))
