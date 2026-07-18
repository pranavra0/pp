type fenced_policy = Retry | Abort | Ask
type t = {
  source_roots : Paths.canonical list;
  initial_capabilities : Capability.t list;
  command_argv : string list;
  program_argv : string list;
  program_files : string list;
  initial_grant_specs : string list;
  program_reconcile_root : string option;
  program_supervise : bool;
  program_member_name : string option;
  program_desired_object : (string * string) option;
  gc_keep_epochs : int;
  fenced_policy : fenced_policy;
}

let create ~source_roots ~initial_capabilities ~command_argv ~program_argv ~program_files
    ~initial_grant_specs ~program_reconcile_root ~program_supervise
    ~program_member_name ~program_desired_object ~gc_keep_epochs ~fenced_policy =
  if gc_keep_epochs <= 0 then Error "--gc-keep-epochs requires a positive integer"
  else Ok { source_roots; initial_capabilities; command_argv; program_argv; program_files;
            initial_grant_specs; program_reconcile_root; program_supervise;
            program_member_name; program_desired_object; gc_keep_epochs;
            fenced_policy }

let source_roots t = t.source_roots
let initial_capabilities t = t.initial_capabilities
let command_argv t = t.command_argv
let program_argv t = t.program_argv
let program_files t = t.program_files
let initial_grant_specs t = t.initial_grant_specs
let program_reconcile_root t = t.program_reconcile_root
let program_supervise t = t.program_supervise
let program_member_name t = t.program_member_name
let program_desired_object t = t.program_desired_object
let gc_keep_epochs t = t.gc_keep_epochs
let fenced_policy t = t.fenced_policy
let fenced_policy_name = function Retry -> "retry" | Abort -> "abort" | Ask -> "ask"
