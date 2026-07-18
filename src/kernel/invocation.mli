type fenced_policy = Retry | Abort | Ask
type t

val create :
  source_roots:Paths.canonical list ->
  initial_capabilities:Capability.t list -> command_argv:string list ->
  program_argv:string list -> program_files:string list ->
  initial_grant_specs:string list -> program_reconcile_root:string option ->
  program_supervise:bool -> program_member_name:string option ->
  program_desired_object:(string * string) option -> gc_keep_epochs:int ->
  fenced_policy:fenced_policy -> (t, string) result

val source_roots : t -> Paths.canonical list
val initial_capabilities : t -> Capability.t list
val command_argv : t -> string list
val program_argv : t -> string list
val program_files : t -> string list
val initial_grant_specs : t -> string list
val program_reconcile_root : t -> string option
val program_supervise : t -> bool
val program_member_name : t -> string option
val program_desired_object : t -> (string * string) option
val gc_keep_epochs : t -> int
val fenced_policy : t -> fenced_policy
val fenced_policy_name : fenced_policy -> string
