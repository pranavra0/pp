open Pp_runtime
open Pp_kernel
type fmt_target = To_braces | To_sexpr

type t

val parse : string list -> t
val print_help : t -> unit

val command_argv : t -> string list
val program_argv : t -> string list
val files : t -> string list
val grants : t -> string list
val eval_string : t -> string option
val reconcile_root : t -> string option
val supervise : t -> bool
val member_name : t -> string option
val desired_object : t -> (string * string) option
val publish_object_root : t -> string option
val watch : t -> bool
val watch_interval : t -> float
val stabilize : t -> bool
val schedule_policy : t -> Scheduler.policy
val schedule_explicit : t -> bool
val fenced_policy : t -> Invocation.fenced_policy
val gc_keep_epochs : t -> int
val gc_grace_seconds : t -> float
val gc : t -> bool
val update_islands : t -> bool
val fetch_islands : t -> bool
val pin_file : t -> string option
val dump_pins_file : t -> string option
val emit_braces_file : t -> string option
val roundtrip_braces_file : t -> string option
val fmt : t -> (fmt_target * string * bool) option
val compare_hash : t -> (string * string) option
val list_comments : t -> ([ `Sexpr | `Brace ] * string) option
val why : t -> bool
val no_cache : t -> bool
val check : t -> bool
val graph : t -> bool
val lint_file : t -> string option
val island_pins : t -> string option
val cluster_init : t -> bool
val mint_token : t -> (string * int) option
val transport_push : t -> (string * string * string) option
val transport_pull : t -> (string * string * string) option
val serve_hit : t -> (string * string * string * string) option
val recv_hit : t -> (string * string) option
val remote_node : t -> (string * string * string * string * string) option
val check_kernel_props : t -> (int * int) option
val kernel_fixture : t -> string option
val version : t -> bool
val help : t -> bool
val dump_surface_tables : t -> bool
val dump_builtins : t -> bool
