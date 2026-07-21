open Pp_kernel

module LocalDir : sig
  type t = string

  val push_object : t -> hash:string -> unit
  val push_blob : t -> hash:string -> unit
  val push_trace : t -> key:string -> unit
  val pull_object : t -> hash:string -> unit
  val pull_blob : t -> hash:string -> unit
  val pull_trace : t -> key:string -> unit
  val control : t -> request:string -> string
end

type reply_decision =
  | RHit of {
      key : string;
      result_hash : string;
      blob_hashes : string list;
    }
  | RMiss of string
  | RDeny of string * string

val serve_hit :
  Host_services.t ->
  key:string -> token_text:string -> shared_root:string -> string
val parse_reply_text : string -> reply_decision option
val recv_hit : reply_text:string -> shared_root:string -> reply_decision
