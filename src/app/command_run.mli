open Pp_kernel
val run_files : ?retain_thunks:bool -> App_context.t -> Cli.t -> string list -> Core_model.value option
val compute_desired : App_context.t -> Cli.t -> Core_model.value option -> Core_model.value
val select_member_slice : Cli.t -> Core_model.value -> Core_model.value
