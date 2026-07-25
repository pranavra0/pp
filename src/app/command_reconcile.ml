open Pp_runtime
open Pp_kernel
open Source_error
let fenced_decision cli (entry : Journal.fenced_entry) =
  match Cli.fenced_policy cli with
  | Invocation.Retry -> Fenced.Retry
  | Invocation.Abort -> Fenced.Abort
  | Invocation.Ask ->
      if not (Unix.isatty Unix.stdin) then
        command "fenced: unknown-status policy is 'ask' but stdin is not a tty; use --fenced-policy retry|abort for non-interactive use";
      Printf.printf "Fenced action %s (kind=%s) has unknown status.  Retry? [y/N]: %!"
        entry.Journal.fe_key entry.Journal.fe_kind;
      let line = try input_line stdin with End_of_file -> "n" in
      if String.lowercase_ascii line = "y" then Fenced.Retry else Fenced.Abort

let recover ctx cli =
  let reconciliation = App_context.reconciliation ctx in
  Dynamic_scope.with_top_level
    (App_context.session ctx) (App_context.invocation ctx)
    ~f:(fun () ->
      if Reconciliation.should_run reconciliation then begin
        let count = Reconciliation.recover reconciliation ~decide:(fenced_decision cli) in
        if count > 0 then
          Printf.eprintf "[fenced] %d unknown-status action(s) in journal; applying policy=%s\n%!"
            count (Invocation.fenced_policy_name (Cli.fenced_policy cli))
      end) ()

let run_pass ctx cli last =
  let reconciliation = App_context.reconciliation ctx in
  if Reconciliation.should_run reconciliation then
    Reconciliation.run reconciliation
      (Command_run.select_member_slice cli
         (Command_run.compute_desired ctx cli last))
