open Pp_kernel
open Pp_runtime

let invalid option_name value =
  Source_error.command ("invalid " ^ option_name ^ ": " ^ value)

let schedule spec =
  match String.split_on_char ':' spec with
  | ["serial"] -> Scheduler.Serial
  | ["parallel"; width] ->
      (match int_of_string_opt width with
       | Some width when width > 0 -> Scheduler.Parallel width
       | _ -> invalid "--schedule parallel width" width)
  | ["race"; width] ->
      (match int_of_string_opt width with
       | Some width when width > 0 -> Scheduler.Race width
       | _ -> invalid "--schedule race width" width)
  | ["remote"; member] when member <> "" -> Scheduler.Remote member
  | ["remote"; _] -> Source_error.command
      "invalid --schedule remote spec: empty member name"
  | _ -> invalid "--schedule spec" spec

let fenced_policy = function
  | "retry" -> Invocation.Retry
  | "abort" -> Invocation.Abort
  | "ask" -> Invocation.Ask
  | value -> invalid "--fenced-policy" value

let nonnegative_float ~option_name value =
  match float_of_string_opt value with
  | Some parsed when parsed >= 0.0 -> parsed
  | _ -> invalid option_name value

let positive_int ~option_name value =
  match int_of_string_opt value with
  | Some parsed when parsed > 0 -> parsed
  | _ -> invalid option_name value
