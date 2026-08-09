open Pp_kernel
open Core_model

val map_fields :
  force:(value -> value) -> value -> (value * value) list

val field :
  force:(value -> value) -> (value * value) list -> string -> value option

val string_field :
  force:(value -> value) -> (value * value) list -> string -> string

val runtime_schedule :
  force:(value -> value) -> value -> Scheduler.policy

val custom_scheduler :
  force:(value -> value) -> session:Session.t -> value -> Scheduler.handler

val validate_manifest :
  force:(value -> value) -> (value * value) list -> (value * value) list
