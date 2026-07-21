open Pp_kernel

type pin =
  | File_pin of { cell : string; hash : string }
  | Probe_pin of { name : string; value : Core_model.value }

type reply =
  | Hit of { key : string; result_hash : string; blob_hashes : string list }
  | Miss of string
  | Deny of string * string

val encode_file_pin : cell:string -> hash:string -> string
val encode_probe_pin : name:string -> Core_model.value -> (string, string) result
val decode_pin : string -> (pin, string) result
val encode_reply : reply -> string
val decode_reply : string -> (reply, string) result
